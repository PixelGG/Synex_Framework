local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.persistence = function(deps)
    local platform = assert(deps.platform, 'persistence requires platform')
    local foundation = assert(deps.foundation, 'persistence requires foundation')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local config = deps.config or {}
    local runtimeInstanceId = deps.instanceId
    local manifestSnapshot = type(deps.manifestSnapshot) == 'function'
        and deps.manifestSnapshot or function() return {} end

    local function rotateRight(value, amount)
        return ((value >> amount) | (value << (32 - amount))) & 0xffffffff
    end

    local shaConstants = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }

    local function sha256(input)
        local bytes = { input:byte(1, #input) }
        local bitLength = #bytes * 8
        bytes[#bytes + 1] = 0x80
        while (#bytes % 64) ~= 56 do bytes[#bytes + 1] = 0 end
        local high = math.floor(bitLength / 0x100000000)
        local low = bitLength & 0xffffffff
        for shift = 24, 0, -8 do bytes[#bytes + 1] = (high >> shift) & 0xff end
        for shift = 24, 0, -8 do bytes[#bytes + 1] = (low >> shift) & 0xff end

        local hash = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        }
        for offset = 1, #bytes, 64 do
            local words = {}
            for index = 0, 15 do
                local position = offset + index * 4
                words[index] = ((bytes[position] << 24) | (bytes[position + 1] << 16)
                    | (bytes[position + 2] << 8) | bytes[position + 3]) & 0xffffffff
            end
            for index = 16, 63 do
                local a = words[index - 15]
                local b = words[index - 2]
                local s0 = rotateRight(a, 7) ~ rotateRight(a, 18) ~ (a >> 3)
                local s1 = rotateRight(b, 17) ~ rotateRight(b, 19) ~ (b >> 10)
                words[index] = (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff
            end

            local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
            local e, f, g, h = hash[5], hash[6], hash[7], hash[8]
            for index = 0, 63 do
                local s1 = rotateRight(e, 6) ~ rotateRight(e, 11) ~ rotateRight(e, 25)
                local choice = (e & f) ~ ((~e) & g)
                local temporary1 = (h + s1 + choice + shaConstants[index + 1] + words[index]) & 0xffffffff
                local s0 = rotateRight(a, 2) ~ rotateRight(a, 13) ~ rotateRight(a, 22)
                local majority = (a & b) ~ (a & c) ~ (b & c)
                local temporary2 = (s0 + majority) & 0xffffffff
                h, g, f, e, d, c, b, a = g, f, e, (d + temporary1) & 0xffffffff, c, b, a,
                    (temporary1 + temporary2) & 0xffffffff
            end
            hash[1] = (hash[1] + a) & 0xffffffff
            hash[2] = (hash[2] + b) & 0xffffffff
            hash[3] = (hash[3] + c) & 0xffffffff
            hash[4] = (hash[4] + d) & 0xffffffff
            hash[5] = (hash[5] + e) & 0xffffffff
            hash[6] = (hash[6] + f) & 0xffffffff
            hash[7] = (hash[7] + g) & 0xffffffff
            hash[8] = (hash[8] + h) & 0xffffffff
        end
        local output = {}
        for index = 1, 8 do output[index] = ('%08x'):format(hash[index]) end
        return table.concat(output)
    end

    local adapter = deps.db
    if not adapter then
        adapter = {}
        function adapter.query(sql, parameters) return MySQL.query.await(sql, parameters or {}) end
        function adapter.scalar(sql, parameters) return MySQL.scalar.await(sql, parameters or {}) end
        function adapter.insert(sql, parameters) return MySQL.insert.await(sql, parameters or {}) end
        function adapter.update(sql, parameters) return MySQL.update.await(sql, parameters or {}) end
        function adapter.transaction(statements)
            return MySQL.transaction.await(statements)
        end
        function adapter.startTransaction(handler)
            return MySQL.startTransaction(handler)
        end
    end

    local database = {}
    local databaseDraining = false
    local databaseActivityCount = 0
    local databaseActivitySequence = 0
    local databaseActivities = {}
    local databaseActivityKinds = {}
    local databaseControlDepth = setmetatable({}, { __mode = 'k' })
    local databaseMainControlKey = {}
    local maximumDatabaseDeadlockCount = 9007199254740991
    local databaseDeadlockCounts = {}
    local maximumSlowQueryEntries = 128
    local slowQueryEntries = {}
    local slowQueryCount = 0
    local slowQuerySequence = 0
    local observationSecretFragments = {
        'password', 'passphrase', 'secret', 'credential', 'webhook',
        'privatekey', 'apikey', 'accesstoken', 'refreshtoken', 'license'
    }

    local function databaseControlKey()
        local running = coroutine.running()
        return running or databaseMainControlKey
    end

    local function beginDatabaseActivity(kind)
        local controlKey = databaseControlKey()
        if databaseDraining and (databaseControlDepth[controlKey] or 0) == 0 then
            return nil, foundation.error('DATABASE_DRAINING',
                'The database runtime is draining for Core shutdown.', {
                    retryable = true
                })
        end
        databaseActivitySequence = databaseActivitySequence + 1
        local token = databaseActivitySequence
        databaseActivities[token] = kind
        databaseActivityCount = databaseActivityCount + 1
        databaseActivityKinds[kind] = (databaseActivityKinds[kind] or 0) + 1
        return token, nil
    end

    local function finishDatabaseActivity(token)
        local kind = databaseActivities[token]
        if kind == nil then return false end
        databaseActivities[token] = nil
        databaseActivityCount = math.max(0, databaseActivityCount - 1)
        databaseActivityKinds[kind] = math.max(0, (databaseActivityKinds[kind] or 1) - 1)
        if databaseActivityKinds[kind] == 0 then databaseActivityKinds[kind] = nil end
        return true
    end

    function database:activity()
        local kinds = {}
        for kind, count in pairs(databaseActivityKinds) do kinds[kind] = count end
        return {
            draining = databaseDraining,
            active = databaseActivityCount,
            kinds = kinds
        }
    end

    function database:beginDrain()
        databaseDraining = true
        return self:activity(), nil
    end

    function database:waitForDrain(timeoutMs, pollMs)
        timeoutMs = timeoutMs == nil and 30000 or timeoutMs
        pollMs = pollMs == nil and 10 or pollMs
        if type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < 0 or timeoutMs > 60000
            or type(pollMs) ~= 'number' or math.type(pollMs) ~= 'integer'
            or pollMs < 1 or pollMs > 100 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Database drain timeout or poll interval is outside the supported range.')
        end
        local startedAt = foundation.monotonicMs()
        local maximumPolls = timeoutMs == 0 and 0 or math.ceil(timeoutMs / pollMs)
        local polls = 0
        while databaseActivityCount > 0 and polls < maximumPolls
            and foundation.monotonicMs() - startedAt < timeoutMs do
            polls = polls + 1
            local elapsed = foundation.monotonicMs() - startedAt
            local delay = math.min(pollMs, math.max(0, timeoutMs - elapsed))
            local waited, waitError = foundation.safeCall(platform.wait, delay)
            if not waited then
                return nil, foundation.error('DATABASE_DRAIN_WAIT_FAILED',
                    'The runtime could not wait for database work to drain.', {
                        details = {
                            cause = foundation.failureCode(
                                waitError, 'DATABASE_DRAIN_WAIT_EXCEPTION')
                        }
                    })
            end
        end
        local snapshot = self:activity()
        snapshot.durationMs = math.max(0, foundation.monotonicMs() - startedAt)
        snapshot.polls = polls
        if snapshot.active > 0 then
            return nil, foundation.error('RESTART_DATABASE_DRAIN_TIMEOUT',
                'Core restart preparation timed out while database work remained active.', {
                    retryable = true,
                    details = { active = snapshot.active, timeoutMs = timeoutMs }
                })
        end
        return snapshot, nil
    end

    function database:withControl(handler)
        if type(handler) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Database control work requires a handler.')
        end
        local controlKey = databaseControlKey()
        databaseControlDepth[controlKey] = (databaseControlDepth[controlKey] or 0) + 1
        local invoked, result, handlerError = foundation.safeCall(handler)
        databaseControlDepth[controlKey] = math.max(0,
            (databaseControlDepth[controlKey] or 1) - 1)
        if databaseControlDepth[controlKey] == 0 then databaseControlDepth[controlKey] = nil end
        if not invoked then
            return nil, foundation.error('DATABASE_CONTROL_FAILED',
                'Database shutdown control work raised an exception.', {
                    details = {
                        cause = foundation.failureCode(result, 'DATABASE_CONTROL_EXCEPTION')
                    }
                })
        end
        return result, handlerError
    end

    local function failureDetails(value)
        if type(value) == 'table' then
            return tostring(value.code or value.errno or value.sqlState or value.sqlstate or value.message or '')
        end
        return tostring(value or '')
    end
    local databaseClassifications = {
        [1062] = 'UNIQUE_VIOLATION',
        [1048] = 'NOT_NULL_VIOLATION',
        [1205] = 'LOCK_TIMEOUT',
        [1213] = 'DEADLOCK',
        [1406] = 'VALUE_TOO_LONG',
        [1451] = 'FOREIGN_KEY_VIOLATION',
        [1452] = 'FOREIGN_KEY_VIOLATION',
        [3819] = 'CHECK_CONSTRAINT_VIOLATION'
    }
    local databaseCodeClassifications = {
        ER_DUP_ENTRY = 'UNIQUE_VIOLATION',
        ER_BAD_NULL_ERROR = 'NOT_NULL_VIOLATION',
        ER_LOCK_WAIT_TIMEOUT = 'LOCK_TIMEOUT',
        ER_LOCK_DEADLOCK = 'DEADLOCK',
        ER_DATA_TOO_LONG = 'VALUE_TOO_LONG',
        ER_ROW_IS_REFERENCED_2 = 'FOREIGN_KEY_VIOLATION',
        ER_NO_REFERENCED_ROW_2 = 'FOREIGN_KEY_VIOLATION',
        ER_CHECK_CONSTRAINT_VIOLATED = 'CHECK_CONSTRAINT_VIOLATION'
    }
    local function failureMetadata(value)
        local metadata = {}
        if type(value) ~= 'table' then return metadata end
        local errno = tonumber(value.errno)
        if errno and math.type(errno) == 'integer' and errno >= 0 and errno <= 999999 then
            metadata.errno = errno
        end
        local sqlState = value.sqlState or value.sqlstate
        if type(sqlState) == 'string' and #sqlState == 5
            and sqlState:match('^[A-Za-z0-9]+$') then
            metadata.sqlState = sqlState:upper()
        end
        metadata.databaseCode = databaseClassifications[errno]
            or (type(value.code) == 'string' and databaseCodeClassifications[value.code])
            or 'DATABASE_FAILURE'
        return metadata
    end
    local function logDatabaseFailure(message, fields, failure, failureType)
        local safeFields = {}
        for key, value in pairs(fields or {}) do safeFields[key] = value end
        for key, value in pairs(failureMetadata(failure)) do safeFields[key] = value end
        safeFields.failureType = failureType
        logger:error(message, safeFields)
    end
    local function isRetryableDeadlock(value)
        local detail = failureDetails(value):lower()
        return detail:find('1213', 1, true) ~= nil
            or detail:find('40001', 1, true) ~= nil
            or detail:find('deadlock', 1, true) ~= nil
    end
    local function recordDatabaseDeadlock(kind)
        local current = databaseDeadlockCounts[kind] or 0
        if current < maximumDatabaseDeadlockCount then
            current = current + 1
            databaseDeadlockCounts[kind] = current
        end
        metrics:gauge('synex_db_deadlocks_total', { kind = kind }, current)
    end
    local function attribution()
        local context = foundation.currentContext and foundation.currentContext() or nil
        return {
            resource = context and (context.provider or context.caller) or 'synex_core',
            operation = context and (context.contract or context.service or context.hook) or 'kernel',
            traceId = context and context.traceId or nil
        }
    end
    local function safeObservationText(value, fallback, maximum)
        if type(value) ~= 'string' or #value < 1 or #value > maximum
            or value:find('[%z\1-\31\127]')
            or not value:match('^[A-Za-z0-9][A-Za-z0-9_.:@%-]*$') then
            return fallback
        end
        return value
    end
    local function safeObservationTrace(value)
        local candidate = safeObservationText(value, nil, 128)
        if candidate == nil then return nil end
        local normalized = candidate:lower()
        for _, fragment in ipairs(observationSecretFragments) do
            if normalized:find(fragment, 1, true) then return nil end
        end
        return candidate
    end
    local function recordSlowQuery(kind, statementHash, durationMs, operationOk)
        local attributed = attribution()
        local resource = safeObservationText(attributed.resource, 'synex_core', 64)
        local operation = safeObservationText(attributed.operation, 'kernel', 128)
        local traceId = safeObservationTrace(attributed.traceId)
        local key = table.concat({ resource, operation, kind, statementHash }, '|')
        local entry = slowQueryEntries[key]
        if entry == nil then
            if slowQueryCount >= maximumSlowQueryEntries then
                local oldestKey, oldestSequence = nil, math.huge
                for candidateKey, candidate in pairs(slowQueryEntries) do
                    if candidate.lastSequence < oldestSequence then
                        oldestKey, oldestSequence = candidateKey, candidate.lastSequence
                    end
                end
                if oldestKey ~= nil then
                    slowQueryEntries[oldestKey] = nil
                    slowQueryCount = math.max(0, slowQueryCount - 1)
                end
            end
            entry = {
                resource = resource,
                operation = operation,
                kind = kind,
                statementHash = statementHash,
                occurrences = 0,
                maximumDurationMs = 0,
                firstObservedAt = foundation.utcIso()
            }
            slowQueryEntries[key] = entry
            slowQueryCount = slowQueryCount + 1
        end
        slowQuerySequence = slowQuerySequence + 1
        entry.occurrences = math.min(2147483647, entry.occurrences + 1)
        entry.durationMs = math.max(0, durationMs)
        entry.maximumDurationMs = math.max(entry.maximumDurationMs, entry.durationMs)
        entry.traceId = traceId
        entry.status = operationOk and 'SUCCESS' or 'ERROR'
        entry.observedAt = foundation.utcIso()
        entry.lastSequence = slowQuerySequence
    end

    function database:slowQueries(request)
        request = request == nil and {} or request
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Slow-query history requires a bounded plain request.')
        end
        for key in pairs(request) do
            if key ~= 'cursor' and key ~= 'limit' then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Slow-query history request contains an unknown property.')
            end
        end
        local limit = request.limit == nil and 25 or request.limit
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 50 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Slow-query history limit must be an integer from 1 through 50.')
        end
        local cursor = nil
        if request.cursor ~= nil then
            if type(request.cursor) ~= 'string' or #request.cursor < 1
                or #request.cursor > 20 or not request.cursor:match('^[1-9]%d*$') then
                return nil, foundation.error('INVALID_CURSOR',
                    'Slow-query history cursor is invalid.')
            end
            cursor = tonumber(request.cursor)
            if cursor == nil or cursor > slowQuerySequence + 1 then
                return nil, foundation.error('INVALID_CURSOR',
                    'Slow-query history cursor is invalid.')
            end
        end
        local candidates = {}
        for _, entry in pairs(slowQueryEntries) do
            if cursor == nil or entry.lastSequence < cursor then
                candidates[#candidates + 1] = entry
            end
        end
        table.sort(candidates, function(left, right)
            return left.lastSequence > right.lastSequence
        end)
        local hasMore = #candidates > limit
        local items = {}
        for index = 1, math.min(#candidates, limit) do
            local entry = candidates[index]
            items[index] = {
                cursor = tostring(entry.lastSequence),
                resource = entry.resource,
                operation = entry.operation,
                kind = entry.kind,
                statementHash = entry.statementHash,
                durationMs = entry.durationMs,
                maximumDurationMs = entry.maximumDurationMs,
                traceId = entry.traceId,
                occurrences = entry.occurrences,
                status = entry.status,
                firstObservedAt = entry.firstObservedAt,
                observedAt = entry.observedAt
            }
        end
        return {
            status = 'AVAILABLE',
            items = items,
            nextCursor = hasMore and tostring(items[#items].cursor) or nil,
            hasMore = hasMore,
            truncated = hasMore,
            retained = slowQueryCount,
            maximumRetained = maximumSlowQueryEntries,
            thresholdMs = config.queryWarnMs or 250,
            rawSqlExposed = false,
            parametersExposed = false
        }, nil
    end
    local function measured(kind, sql, parameters)
        local activityToken, activityError = beginDatabaseActivity(kind)
        if not activityToken then return nil, activityError end
        local started = foundation.monotonicMs()
        local ok, value, adapterError = foundation.safeCall(adapter[kind], sql, parameters or {})
        finishDatabaseActivity(activityToken)
        local duration = foundation.monotonicMs() - started
        local attributed = attribution()
        local valueType = type(value)
        local validShape = (kind == 'query' and valueType == 'table')
            or (kind == 'scalar' and (value == nil or valueType == 'boolean' or valueType == 'number' or valueType == 'string'))
            or ((kind == 'insert' or kind == 'update') and valueType == 'number'
                and value == value and value >= 0 and value < math.huge and value == math.floor(value))
        local operationOk = ok and adapterError == nil and validShape
        local labels = { kind = kind, ok = operationOk, resource = attributed.resource, operation = attributed.operation }
        metrics:increment('synex_db_operations_total', labels)
        metrics:gauge('synex_db_last_duration_ms', { kind = kind, resource = attributed.resource, operation = attributed.operation }, duration)
        metrics:observe('synex_db_duration_ms', { kind = kind, resource = attributed.resource, operation = attributed.operation }, duration)
        if duration >= (config.queryWarnMs or 250) then
            local statementHash = sha256(sql)
            recordSlowQuery(kind, statementHash, duration, operationOk)
            logger:warn('slow database operation', {
                kind = kind, durationMs = duration, statementHash = statementHash,
                resource = attributed.resource, operation = attributed.operation, traceId = attributed.traceId
            })
        end
        if not ok or adapterError ~= nil then
            local failure = ok and adapterError or value
            local deadlock = isRetryableDeadlock(failure)
            if deadlock then recordDatabaseDeadlock(kind) end
            logDatabaseFailure('database operation failed', {
                kind = kind, statementHash = sha256(sql),
                resource = attributed.resource, operation = attributed.operation, traceId = attributed.traceId
            }, failure, ok and 'adapter_error' or 'adapter_exception')
            return nil, foundation.error('DATABASE_ERROR', 'The database operation failed.', {
                retryable = deadlock
            })
        end
        if not validShape then
            logger:error('database adapter returned an invalid result shape', {
                kind = kind, statementHash = sha256(sql), resultType = valueType,
                resource = attributed.resource, operation = attributed.operation, traceId = attributed.traceId
            })
            return nil, foundation.error('DATABASE_RESULT_INVALID', 'The database adapter returned an invalid result.', {
                retryable = true,
                details = { kind = kind, resultType = valueType }
            })
        end
        return value, nil
    end

    function database:query(sql, parameters) return measured('query', sql, parameters) end
    function database:scalar(sql, parameters) return measured('scalar', sql, parameters) end
    function database:insert(sql, parameters) return measured('insert', sql, parameters) end
    function database:update(sql, parameters) return measured('update', sql, parameters) end
    function database:validateUtcSession()
        local value, queryError = self:scalar(
            'SELECT TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), CURRENT_TIMESTAMP()) AS offset_seconds', {})
        if queryError then return nil, queryError end
        local offsetSeconds = tonumber(value)
        if offsetSeconds ~= 0 then
            metrics:increment('synex_db_utc_validation_total', { ok = false })
            return nil, foundation.error('DATABASE_TIMEZONE_INVALID',
                'The database session timezone must resolve CURRENT_TIMESTAMP as UTC.', {
                    details = { offsetSeconds = offsetSeconds }
                })
        end
        metrics:increment('synex_db_utc_validation_total', { ok = true })
        return true, nil
    end
    function database:transaction(statements)
        if type(statements) ~= 'table' or #statements == 0 then
            return nil, foundation.error('INVALID_ARGUMENT', 'A non-empty transaction statement list is required.')
        end
        local maximumAttempts = 1 + math.max(0, math.min(tonumber(config.deadlockRetries) or 0, 5))
        for attempt = 1, maximumAttempts do
            local activityToken, activityError = beginDatabaseActivity('batch')
            if not activityToken then return nil, activityError end
            local started = foundation.monotonicMs()
            local ok, result, adapterError = foundation.safeCall(adapter.transaction, statements)
            finishDatabaseActivity(activityToken)
            local duration = foundation.monotonicMs() - started
            local failure = ok and adapterError or result
            if duration >= (config.queryWarnMs or 250) then
                recordSlowQuery('batch', sha256('batch:' .. tostring(#statements)),
                    duration, ok and result == true)
            end
            metrics:increment('synex_db_transactions_total', { ok = ok and result == true, attempt = attempt })
            if ok and result == true then return true, nil end
            local deadlock = isRetryableDeadlock(failure)
            if deadlock then recordDatabaseDeadlock('batch') end
            if deadlock and attempt < maximumAttempts then
                metrics:increment('synex_db_deadlock_retries_total', { kind = 'batch' })
                platform.wait(math.min(100, attempt * 10))
            else
                logDatabaseFailure('database transaction failed', {
                    durationMs = duration, attempt = attempt
                }, failure, ok and 'rejected' or 'adapter_exception')
                if not ok then
                    return nil, foundation.error('DATABASE_ERROR', 'The database transaction failed.', { retryable = deadlock })
                end
                return nil, foundation.error('TRANSACTION_REJECTED', 'The database rejected the transaction.', { retryable = deadlock })
            end
        end
        return nil, foundation.error('TRANSACTION_REJECTED', 'The database rejected the transaction.')
    end
    function database:withTransaction(handler)
        if type(handler) ~= 'function' or type(adapter.startTransaction) ~= 'function' then
            return nil, foundation.error('TRANSACTION_UNAVAILABLE', 'Interactive transactions are unavailable in this adapter.')
        end
        local maximumAttempts = 1 + math.max(0, math.min(tonumber(config.deadlockRetries) or 0, 5))
        for attempt = 1, maximumAttempts do
            local activityToken, activityError = beginDatabaseActivity('interactive')
            if not activityToken then return nil, activityError end
            local started = foundation.monotonicMs()
            local ok, result, adapterError = foundation.safeCall(adapter.startTransaction, handler)
            finishDatabaseActivity(activityToken)
            local duration = foundation.monotonicMs() - started
            local failure = ok and adapterError or result
            if duration >= (config.queryWarnMs or 250) then
                recordSlowQuery('interactive', sha256('interactive'),
                    duration, ok and result == true)
            end
            metrics:increment('synex_db_interactive_transactions_total', { ok = ok and result == true, attempt = attempt })
            if duration >= 25000 then logger:warn('interactive transaction approached the oxmysql hard timeout', { durationMs = duration }) end
            if ok and result == true then return true, nil end
            local deadlock = isRetryableDeadlock(failure)
            if deadlock then recordDatabaseDeadlock('interactive') end
            if deadlock and attempt < maximumAttempts then
                metrics:increment('synex_db_deadlock_retries_total', { kind = 'interactive' })
                platform.wait(math.min(100, attempt * 10))
            else
                logDatabaseFailure('interactive database transaction failed', {
                    durationMs = duration, attempt = attempt
                }, failure, ok and 'rejected' or 'adapter_exception')
                if not ok then
                    return nil, foundation.error('DATABASE_ERROR', 'The interactive database transaction failed.', { retryable = deadlock })
                end
                return nil, foundation.error('TRANSACTION_REJECTED', 'The database rejected the interactive transaction.', { retryable = deadlock })
            end
        end
        return nil, foundation.error('TRANSACTION_REJECTED', 'The database rejected the interactive transaction.')
    end

    local migrationManager = {}
    local leaseName = 'schema_migrations'
    local leaseOwner = tostring(deps.instanceId or foundation.nextId('instance'))
        .. ':migration:' .. foundation.nextId('migration')
    if #leaseOwner > 96 then error('migration lease owner exceeds the persisted bound') end
    local leaseSeconds = math.max(10, math.min(config.migrationLeaseSeconds or 30, 300))
    local fence = nil
    local migrationChecksumCorrections = {
        ['synex_core:021_worker_queue_scalability'] = {
            previous = '6d314f977f47fa39125c9597172e75fa05d80bfbd310aaf6be4c5584f6823b59',
            current = '5add0fed6935b83e7fd0905c188c1e534a6636d5d935fea1a28a145f7b533b7c'
        }
    }

    local function migrationChecksumAccepted(resourceName, migrationId, checksum, actual, applied)
        if actual == checksum then return true end
        local correction = migrationChecksumCorrections[resourceName .. ':' .. migrationId]
        return correction ~= nil and applied ~= nil
            and applied.checksum_sha256 == correction.previous
            and checksum == correction.current and actual == correction.previous
    end

    local bootstrapStatements = {
        [[CREATE TABLE IF NOT EXISTS `synex_schema_migrations` (
            `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `applied_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
            `duration_ms` INT UNSIGNED NOT NULL,
            `instance_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            PRIMARY KEY (`resource_name`, `migration_id`),
            CONSTRAINT `chk_schema_migrations_checksum`
                CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$')
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS `synex_schema_migration_attempts` (
            `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
            `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
            `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
            `finished_at` DATETIME(6) NULL,
            `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
            PRIMARY KEY (`resource_name`, `migration_id`),
            KEY `idx_schema_migration_attempts_state` (`state`, `updated_at`),
            CONSTRAINT `chk_schema_migration_attempts_checksum`
                CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$'),
            CONSTRAINT `chk_schema_migration_attempts_state`
                CHECK (`state` IN ('applying', 'applied', 'failed')),
            CONSTRAINT `chk_schema_migration_attempts_count` CHECK (`attempts` > 0),
            CONSTRAINT `chk_schema_migration_attempts_finished`
                CHECK ((`state` = 'applying' AND `finished_at` IS NULL)
                    OR (`state` IN ('applied', 'failed') AND `finished_at` IS NOT NULL))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        [[CREATE TABLE IF NOT EXISTS `synex_schema_migration_fences` (
            `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `owner_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `fencing_token` BIGINT UNSIGNED NOT NULL,
            `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `statement_count` SMALLINT UNSIGNED NOT NULL,
            `completed_statements` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
            `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
            `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
            `finished_at` DATETIME(6) NULL,
            `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
            PRIMARY KEY (`resource_name`, `migration_id`),
            KEY `idx_schema_migration_fences_state` (`state`, `updated_at`),
            KEY `idx_schema_migration_fences_owner` (`owner_id`, `fencing_token`),
            CONSTRAINT `chk_schema_migration_fences_checksum`
                CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$'),
            CONSTRAINT `chk_schema_migration_fences_token`
                CHECK (`fencing_token` > 0),
            CONSTRAINT `chk_schema_migration_fences_state`
                CHECK (`state` IN ('applying', 'applied', 'failed', 'indeterminate')),
            CONSTRAINT `chk_schema_migration_fences_progress`
                CHECK (`completed_statements` <= `statement_count`),
            CONSTRAINT `chk_schema_migration_fences_finished`
                CHECK ((`state` = 'applying' AND `finished_at` IS NULL)
                    OR (`state` IN ('applied', 'failed', 'indeterminate') AND `finished_at` IS NOT NULL))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;]],
        [[CREATE TABLE IF NOT EXISTS `synex_cluster_leases` (
            `lease_name` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `owner_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            `fencing_token` BIGINT UNSIGNED NOT NULL,
            `expires_at` DATETIME(6) NOT NULL,
            `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
            PRIMARY KEY (`lease_name`),
            KEY `idx_cluster_leases_expiry` (`expires_at`),
            CONSTRAINT `chk_cluster_leases_fencing_token`
                CHECK (`fencing_token` > 0)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]
    }

    function migrationManager:bootstrap()
        for _, sql in ipairs(bootstrapStatements) do
            local _, err = database:update(sql, {})
            if err then return nil, err end
        end
        return true, nil
    end

    function migrationManager:acquireLease()
        local _, updateError = database:update([[UPDATE `synex_cluster_leases`
            SET `owner_id` = ?, `fencing_token` = `fencing_token` + 1,
                `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
            WHERE `lease_name` = ? AND (`expires_at` < CURRENT_TIMESTAMP(6) OR `owner_id` = ?)]],
            { leaseOwner, leaseSeconds, leaseName, leaseOwner })
        if updateError then return nil, updateError end
        local _, insertError = database:update([[INSERT IGNORE INTO `synex_cluster_leases`
            (`lease_name`, `owner_id`, `fencing_token`, `expires_at`)
            VALUES (?, ?, 1, TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
            { leaseName, leaseOwner, leaseSeconds })
        if insertError then return nil, insertError end
        local rows, selectErr = database:query(
            'SELECT `owner_id`, `fencing_token`, (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid` FROM `synex_cluster_leases` WHERE `lease_name` = ?',
            { leaseName })
        if selectErr then return nil, selectErr end
        local row = rows and rows[1]
        if not row or row.owner_id ~= leaseOwner or tonumber(row.valid) ~= 1 then
            return nil, foundation.error('MIGRATION_LEASE_BUSY', 'Another server instance owns the migration lease.', { retryable = true })
        end
        fence = tonumber(row.fencing_token)
        return fence, nil
    end

    function migrationManager:renewLease()
        if not fence then return nil, foundation.error('LEASE_LOST', 'No migration lease is held.') end
        local affected, err = database:update([[UPDATE `synex_cluster_leases`
            SET `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
            WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ? AND `expires_at` > CURRENT_TIMESTAMP(6)]],
            { leaseSeconds, leaseName, leaseOwner, fence })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then
            fence = nil
            return nil, foundation.error('LEASE_LOST', 'The migration lease fencing token is no longer valid.')
        end
        return true, nil
    end

    function migrationManager:releaseLease()
        if not fence then return true end
        local _, releaseError = database:update([[UPDATE `synex_cluster_leases` SET `expires_at` = CURRENT_TIMESTAMP(6)
            WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?]],
            { leaseName, leaseOwner, fence })
        if releaseError then
            logger:error('migration lease release failed', {
                leaseName = leaseName,
                owner = leaseOwner,
                code = releaseError.code
            })
            return nil, releaseError
        end
        fence = nil
        return true
    end

    function migrationManager:snapshot(maximumResources)
        maximumResources = maximumResources == nil and 256 or maximumResources
        if type(maximumResources) ~= 'number' or math.type(maximumResources) ~= 'integer'
            or maximumResources < 1 or maximumResources > 256 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Migration snapshot limit must be an integer from 1 through 256.')
        end
        local recordMaximum = math.min(4096, math.max(64, maximumResources * 16))
        local attemptRows, attemptError = database:query([[SELECT `resource_name`, `migration_id`,
                `state`, `attempts`
            FROM `synex_schema_migration_attempts`
            ORDER BY `resource_name`, `migration_id` LIMIT ?]], { recordMaximum + 1 })
        if attemptError then return nil, attemptError end
        local fenceRows, fenceError = database:query([[SELECT `resource_name`, `migration_id`, `state`
            FROM `synex_schema_migration_fences`
            ORDER BY `resource_name`, `migration_id` LIMIT ?]], { recordMaximum + 1 })
        if fenceError then return nil, fenceError end
        if type(attemptRows) ~= 'table' or type(fenceRows) ~= 'table'
            or #attemptRows > recordMaximum + 1 or #fenceRows > recordMaximum + 1 then
            return nil, foundation.error('MIGRATION_SNAPSHOT_INVALID',
                'The bounded migration snapshot is invalid.', { retryable = true })
        end
        local attemptStates = { applying = true, applied = true, failed = true }
        local fenceStates = { applying = true, applied = true, failed = true, indeterminate = true }
        local effective = {}
        local function identity(row, states, includeAttempts)
            local resource = type(row) == 'table' and row.resource_name or nil
            local migration = type(row) == 'table' and row.migration_id or nil
            local state = type(row) == 'table' and row.state or nil
            local attempts = includeAttempts and tonumber(row.attempts) or 0
            if type(resource) ~= 'string' or #resource < 1 or #resource > 64
                or not resource:match('^[a-z][a-z0-9_]*$')
                or type(migration) ~= 'string' or #migration < 1 or #migration > 96
                or not migration:match('^%d%d%d_[a-z0-9_]+$') or not states[state]
                or not attempts or math.type(attempts) ~= 'integer'
                or attempts < (includeAttempts and 1 or 0) or attempts > 4294967295 then
                return nil, foundation.error('MIGRATION_SNAPSHOT_INVALID',
                    'The bounded migration snapshot contains an invalid row.', { retryable = true })
            end
            return {
                key = resource .. '\0' .. migration,
                resource = resource,
                migration = migration,
                state = state,
                attempts = attempts
            }, nil
        end
        for index = 1, math.min(#attemptRows, recordMaximum) do
            local entry, entryError = identity(attemptRows[index], attemptStates, true)
            if not entry then return nil, entryError end
            effective[entry.key] = entry
        end
        for index = 1, math.min(#fenceRows, recordMaximum) do
            local entry, entryError = identity(fenceRows[index], fenceStates, false)
            if not entry then return nil, entryError end
            local previous = effective[entry.key]
            if previous then entry.attempts = previous.attempts end
            effective[entry.key] = entry
        end

        local grouped = {}
        for _, row in pairs(effective) do
            local entry = grouped[row.resource]
            if not entry then
                entry = {
                    resource = row.resource,
                    defined = 0, applied = 0, applying = 0,
                    failed = 0, indeterminate = 0, attempts = 0
                }
                grouped[row.resource] = entry
            end
            entry.defined = entry.defined + 1
            entry[row.state] = entry[row.state] + 1
            entry.attempts = entry.attempts + row.attempts
        end
        local resourceNames = {}
        for resource in pairs(grouped) do resourceNames[#resourceNames + 1] = resource end
        table.sort(resourceNames)
        local resources = {}
        local totals = {
            defined = 0, applied = 0, applying = 0, failed = 0, indeterminate = 0, attempts = 0
        }
        for index = 1, math.min(#resourceNames, maximumResources) do
            local entry = grouped[resourceNames[index]]
            resources[index] = entry
            for key in pairs(totals) do totals[key] = totals[key] + entry[key] end
        end
        local recordsTruncated = #attemptRows > recordMaximum or #fenceRows > recordMaximum
        return {
            resources = resources,
            totals = totals,
            truncated = recordsTruncated or #resourceNames > maximumResources,
            recordsTruncated = recordsTruncated,
            recordMaximum = recordMaximum
        }, nil
    end

    function migrationManager:details(request)
        request = request or {}
        if type(request) ~= 'table' or getmetatable(request) ~= nil then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Migration detail options must be a plain object.')
        end
        for key in pairs(request) do
            if key ~= 'cursor' and key ~= 'limit' then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Migration detail options contain an unsupported field.')
            end
        end
        local limit = request.limit or 25
        local cursor = request.cursor
        local cursorResource, cursorMigration
        if type(cursor) == 'string' then
            cursorResource, cursorMigration = cursor:match(
                '^([a-z][a-z0-9_]*)|(%d%d%d_[a-z0-9_]+)$')
        end
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 50
            or cursor ~= nil and (cursorResource == nil or cursorMigration == nil
                or #cursorResource > 64 or #cursorMigration > 96) then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Migration detail cursor or limit is invalid.')
        end
        local detailSql = [[SELECT `observed`.`resource_name`,
                `observed`.`migration_id`,
                `marker`.`checksum_sha256` AS `marker_checksum`,
                `attempt`.`checksum_sha256` AS `attempt_checksum`,
                `fence`.`checksum_sha256` AS `fence_checksum`,
                `attempt`.`state` AS `attempt_state`,
                `fence`.`state` AS `fence_state`,
                CAST(`attempt`.`attempts` AS CHAR) AS `attempts`,
                COALESCE(`fence`.`last_error_code`, `attempt`.`last_error_code`)
                    AS `last_error_code`,
                DATE_FORMAT(`marker`.`applied_at`, '%Y-%m-%dT%H:%i:%s.%fZ')
                    AS `applied_at`,
                CAST(`marker`.`duration_ms` AS CHAR) AS `duration_ms`
            FROM (
                SELECT `resource_name`, `migration_id`
                    FROM `synex_schema_migration_attempts`
                UNION
                SELECT `resource_name`, `migration_id`
                    FROM `synex_schema_migrations`
                UNION
                SELECT `resource_name`, `migration_id`
                    FROM `synex_schema_migration_fences`
            ) AS `observed`
            LEFT JOIN `synex_schema_migrations` AS `marker`
                ON `marker`.`resource_name` = `observed`.`resource_name`
                AND `marker`.`migration_id` = `observed`.`migration_id`
            LEFT JOIN `synex_schema_migration_attempts` AS `attempt`
                ON `attempt`.`resource_name` = `observed`.`resource_name`
                AND `attempt`.`migration_id` = `observed`.`migration_id`
            LEFT JOIN `synex_schema_migration_fences` AS `fence`
                ON `fence`.`resource_name` = `observed`.`resource_name`
                AND `fence`.`migration_id` = `observed`.`migration_id`]]
        local parameters
        if cursorResource then
            detailSql = detailSql .. [[
                WHERE `observed`.`resource_name` > ?
                    OR (`observed`.`resource_name` = ?
                        AND `observed`.`migration_id` > ?)]]
            parameters = { cursorResource, cursorResource, cursorMigration, limit + 1 }
        else
            parameters = { limit + 1 }
        end
        detailSql = detailSql .. [[
            ORDER BY `observed`.`resource_name`, `observed`.`migration_id`
            LIMIT ?]]
        local rows, rowsError = database:query(detailSql, parameters)
        if rowsError then return nil, rowsError end
        if type(rows) ~= 'table' or #rows > limit + 1 then
            return nil, foundation.error('MIGRATION_SNAPSHOT_INVALID',
                'The migration detail query returned an invalid page.', { retryable = true })
        end
        local manifestOk, manifests = foundation.safeCall(manifestSnapshot)
        if not manifestOk or type(manifests) ~= 'table' then
            return nil, foundation.error('MIGRATION_MANIFEST_SNAPSHOT_INVALID',
                'The migration manifest snapshot is unavailable.', { retryable = true })
        end
        local definitions, manifestResources, definitionCount = {}, 0, 0
        for resource, manifest in pairs(manifests) do
            manifestResources = manifestResources + 1
            if manifestResources > 2048 or type(resource) ~= 'string'
                or #resource < 1 or #resource > 64
                or not resource:match('^[a-z][a-z0-9_]*$')
                or type(manifest) ~= 'table' or manifest.name ~= resource
                or type(manifest.migrations) ~= 'table' then
                return nil, foundation.error('MIGRATION_MANIFEST_SNAPSHOT_INVALID',
                    'The migration manifest snapshot contains an invalid resource.')
            end
            for _, migration in ipairs(manifest.migrations) do
                definitionCount = definitionCount + 1
                if definitionCount > 4096 or type(migration) ~= 'table'
                    or type(migration.id) ~= 'string' or #migration.id > 96
                    or not migration.id:match('^%d%d%d_[a-z0-9_]+$')
                    or type(migration.path) ~= 'string' or #migration.path > 240
                    or not migration.path:match('^migrations/[A-Za-z0-9%._/-]+%.sql$')
                    or migration.path:find('..', 1, true) then
                    return nil, foundation.error('MIGRATION_MANIFEST_SNAPSHOT_INVALID',
                        'The migration manifest snapshot contains an invalid definition.')
                end
                local key = resource .. '|' .. migration.id
                if definitions[key] ~= nil then
                    return nil, foundation.error('MIGRATION_MANIFEST_SNAPSHOT_INVALID',
                        'The migration manifest snapshot contains a duplicate definition.')
                end
                definitions[key] = {
                    resource = resource,
                    migration = migration.id,
                    path = migration.path
                }
            end
        end

        local attemptStates = { applying = true, applied = true, failed = true }
        local fenceStates = {
            applying = true, applied = true, failed = true, indeterminate = true
        }
        local candidates = {}
        for index = 1, #rows do
            local row = rows[index]
            local resource = type(row) == 'table' and row.resource_name or nil
            local migration = type(row) == 'table' and row.migration_id or nil
            local markerChecksum = type(row) == 'table' and row.marker_checksum or nil
            local attemptChecksum = type(row) == 'table' and row.attempt_checksum or nil
            local fenceChecksum = type(row) == 'table' and row.fence_checksum or nil
            local attemptState = type(row) == 'table' and row.attempt_state or nil
            local fenceState = type(row) == 'table' and row.fence_state or nil
            local attempts = type(row) == 'table' and tonumber(row.attempts) or nil
            local durationMs = type(row) == 'table' and tonumber(row.duration_ms) or nil
            if type(resource) ~= 'string' or not resource:match('^[a-z][a-z0-9_]*$')
                or #resource > 64 or type(migration) ~= 'string'
                or not migration:match('^%d%d%d_[a-z0-9_]+$') or #migration > 96
                or markerChecksum ~= nil and (type(markerChecksum) ~= 'string'
                    or #markerChecksum ~= 64 or not markerChecksum:match('^[0-9a-f]+$'))
                or attemptChecksum ~= nil and (type(attemptChecksum) ~= 'string'
                    or #attemptChecksum ~= 64 or not attemptChecksum:match('^[0-9a-f]+$'))
                or fenceChecksum ~= nil and (type(fenceChecksum) ~= 'string'
                    or #fenceChecksum ~= 64 or not fenceChecksum:match('^[0-9a-f]+$'))
                or markerChecksum == nil and attemptChecksum == nil and fenceChecksum == nil
                or attemptState ~= nil and not attemptStates[attemptState]
                or fenceState ~= nil and not fenceStates[fenceState]
                or attempts ~= nil and (math.type(attempts) ~= 'integer' or attempts < 1
                    or attempts > 65535)
                or durationMs ~= nil and (math.type(durationMs) ~= 'integer'
                    or durationMs < 0 or durationMs > 4294967295)
                or row.applied_at ~= nil and (type(row.applied_at) ~= 'string'
                    or #row.applied_at < 20 or #row.applied_at > 32
                    or row.applied_at:find('[%z\1-\31\127]'))
                or row.last_error_code ~= nil and (type(row.last_error_code) ~= 'string'
                    or #row.last_error_code < 1 or #row.last_error_code > 64
                    or not row.last_error_code:match('^[A-Z][A-Z0-9_]*$')) then
                return nil, foundation.error('MIGRATION_SNAPSHOT_INVALID',
                    'The migration detail query contains an invalid row.', { retryable = true })
            end
            local key = resource .. '|' .. migration
            candidates[key] = {
                resource = resource,
                migration = migration,
                markerChecksum = markerChecksum,
                attemptChecksum = attemptChecksum,
                fenceChecksum = fenceChecksum,
                attemptState = attemptState,
                fenceState = fenceState,
                attempts = attempts or 0,
                appliedAt = row.applied_at,
                durationMs = durationMs,
                lastErrorCode = row.last_error_code
            }
        end

        local definitionKeys = {}
        for key in pairs(definitions) do
            local definition = definitions[key]
            if cursorResource == nil or definition.resource > cursorResource
                or definition.resource == cursorResource
                    and definition.migration > cursorMigration then
                definitionKeys[#definitionKeys + 1] = key
            end
        end
        table.sort(definitionKeys, function(left, right)
            local leftDefinition, rightDefinition = definitions[left], definitions[right]
            if leftDefinition.resource == rightDefinition.resource then
                return leftDefinition.migration < rightDefinition.migration
            end
            return leftDefinition.resource < rightDefinition.resource
        end)
        for index = 1, math.min(#definitionKeys, limit + 1) do
            local key = definitionKeys[index]
            candidates[key] = candidates[key] or {
                resource = definitions[key].resource,
                migration = definitions[key].migration,
                attempts = 0
            }
        end
        local keys = {}
        for key in pairs(candidates) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right)
            local leftCandidate, rightCandidate = candidates[left], candidates[right]
            if leftCandidate.resource == rightCandidate.resource then
                return leftCandidate.migration < rightCandidate.migration
            end
            return leftCandidate.resource < rightCandidate.resource
        end)

        local items = {}
        local pageFindings = {
            CHECKSUM_MISMATCH = 0,
            MISSING_MIGRATION = 0,
            SCHEMA_DRIFT = 0
        }
        for index = 1, math.min(#keys, limit) do
            local key = keys[index]
            local candidate = candidates[key]
            local definition = definitions[key]
            local expectedChecksum, finding
            if definition then
                local contents = platform.loadResourceFile(
                    definition.resource, definition.path)
                if type(contents) == 'string' then
                    expectedChecksum = sha256(contents:gsub('\r\n', '\n'))
                else
                    finding = 'MISSING_MIGRATION'
                end
            else
                finding = 'SCHEMA_DRIFT'
            end
            local marker = candidate.markerChecksum and {
                checksum_sha256 = candidate.markerChecksum
            } or nil
            if expectedChecksum and not finding then
                for _, checksum in ipairs({
                    candidate.markerChecksum,
                    candidate.attemptChecksum,
                    candidate.fenceChecksum
                }) do
                    if checksum and not migrationChecksumAccepted(candidate.resource,
                        candidate.migration, expectedChecksum, checksum, marker) then
                        finding = 'CHECKSUM_MISMATCH'
                        break
                    end
                end
            end
            local status = candidate.fenceState or candidate.attemptState
                or candidate.markerChecksum and 'applied' or 'missing'
            if not finding then
                if not candidate.markerChecksum and (candidate.fenceState == 'applied'
                    or candidate.attemptState == 'applied')
                    or candidate.markerChecksum and (candidate.fenceState ~= nil
                        and candidate.fenceState ~= 'applied'
                        or candidate.attemptState ~= nil
                            and candidate.attemptState ~= 'applied') then
                    finding = 'SCHEMA_DRIFT'
                elseif definition and candidate.markerChecksum == nil then
                    finding = 'MISSING_MIGRATION'
                end
            end
            if finding then pageFindings[finding] = pageFindings[finding] + 1 end
            items[#items + 1] = {
                resource = candidate.resource,
                migration = candidate.migration,
                checksum = expectedChecksum or candidate.markerChecksum
                    or candidate.fenceChecksum or candidate.attemptChecksum,
                recordedChecksum = candidate.markerChecksum or candidate.fenceChecksum
                    or candidate.attemptChecksum,
                appliedAt = candidate.appliedAt,
                durationMs = candidate.durationMs,
                status = status,
                attempts = candidate.attempts,
                lastErrorCode = candidate.lastErrorCode,
                finding = finding
            }
        end
        local hasMore = #keys > limit
        local last = items[#items]
        return {
            columns = {
                { key = 'resource', label = 'Resource' },
                { key = 'migration', label = 'Migration' },
                { key = 'checksum', label = 'Checksum' },
                { key = 'recordedChecksum', label = 'Recorded checksum' },
                { key = 'appliedAt', label = 'Applied at' },
                { key = 'durationMs', label = 'Duration (ms)' },
                { key = 'status', label = 'Status' },
                { key = 'attempts', label = 'Attempts' },
                { key = 'lastErrorCode', label = 'Last error' },
                { key = 'finding', label = 'Finding' }
            },
            items = items,
            limit = limit,
            hasMore = hasMore,
            nextCursor = hasMore and last
                and (last.resource .. '|' .. last.migration) or nil,
            truncated = hasMore,
            pageFindings = pageFindings,
            findingScope = 'MANIFEST_AND_MIGRATION_MARKERS',
            physicalSchemaInspection = false
        }, nil
    end

    local function splitStatements(contents)
        local statements = {}
        local buffer = {}
        for line in (contents .. '\n'):gmatch('(.-)\r?\n') do
            if line:match('^%s*%-%-%s*synex:statement%s*$') then
                local statement = table.concat(buffer, '\n'):match('^%s*(.-)%s*$')
                if statement ~= '' then statements[#statements + 1] = statement end
                buffer = {}
            else
                buffer[#buffer + 1] = line
            end
        end
        local statement = table.concat(buffer, '\n'):match('^%s*(.-)%s*$')
        if statement ~= '' then statements[#statements + 1] = statement end
        return statements
    end

    local function migrationError(code, message, options)
        options = options or {}
        options.retryable = false
        return foundation.error(code, message, options)
    end

    local function withCurrentMigrationLease(handler)
        local heldFence = fence
        if not heldFence then
            return nil, migrationError('LEASE_LOST', 'No current migration lease fence is held.')
        end
        local operationError, operationResult = nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            local leaseRows = query([[SELECT `owner_id`, `fencing_token`,
                    (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                FROM `synex_cluster_leases`
                WHERE `lease_name` = ? FOR UPDATE]], { leaseName }) or {}
            local leaseRow = leaseRows[1]
            if not leaseRow or leaseRow.owner_id ~= leaseOwner
                or tonumber(leaseRow.fencing_token) ~= heldFence or tonumber(leaseRow.valid) ~= 1 then
                operationError = migrationError('LEASE_LOST',
                    'The migration lease owner or fencing token is no longer current.')
                return false
            end
            local accepted, value, handlerError = handler(query, heldFence)
            if accepted ~= true then
                operationError = handlerError or migrationError('MIGRATION_FENCE_LOST',
                    'The migration ownership fence changed unexpectedly.')
                return false
            end
            operationResult = value
            return true
        end)
        if not committed then return nil, operationError or transactionError end
        return operationResult == nil and true or operationResult, nil
    end

    local function checksumError(resourceName, migrationId, context)
        return migrationError('MIGRATION_CHECKSUM_MISMATCH',
            ('%s migration %s/%s has a different checksum.'):format(context, resourceName, migrationId))
    end

    local function claimMigration(resourceName, migrationId, checksum, statementCount)
        return withCurrentMigrationLease(function(query, heldFence)
            local appliedRows = query([[SELECT `checksum_sha256`, `instance_id`
                FROM `synex_schema_migrations`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local fenceRows = query([[SELECT `checksum_sha256`, `owner_id`, `fencing_token`, `state`,
                    `statement_count`, `completed_statements`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local attemptRows = query([[SELECT `checksum_sha256`, `state`, `attempts`
                FROM `synex_schema_migration_attempts`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local applied, ownedFence, attempt = appliedRows[1], fenceRows[1], attemptRows[1]

            if applied and not migrationChecksumAccepted(
                resourceName, migrationId, checksum, applied.checksum_sha256, applied) then
                return false, nil, checksumError(resourceName, migrationId, 'Applied')
            end
            if ownedFence and not migrationChecksumAccepted(
                resourceName, migrationId, checksum, ownedFence.checksum_sha256, applied) then
                return false, nil, checksumError(resourceName, migrationId, 'Fenced')
            end
            if attempt and not migrationChecksumAccepted(
                resourceName, migrationId, checksum, attempt.checksum_sha256, applied) then
                return false, nil, checksumError(resourceName, migrationId, 'Attempted')
            end

            if applied then
                if ownedFence and ownedFence.state ~= 'applied' then
                    return false, nil, migrationError('MIGRATION_STATE_INCONSISTENT',
                        ('Migration %s/%s has an applied marker but a non-applied fence.'):format(
                            resourceName, migrationId))
                end
                if attempt and attempt.state ~= 'applied' then
                    return false, nil, migrationError('MIGRATION_STATE_INCONSISTENT',
                        ('Migration %s/%s has an applied marker but a non-applied attempt.'):format(
                            resourceName, migrationId))
                end
                if not ownedFence then
                    query([[INSERT INTO `synex_schema_migration_fences`
                        (`resource_name`, `migration_id`, `checksum_sha256`, `owner_id`, `fencing_token`,
                         `state`, `statement_count`, `completed_statements`, `last_error_code`,
                         `started_at`, `finished_at`)
                        VALUES (?, ?, ?, ?, ?, 'applied', ?, ?, NULL,
                            CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))]],
                        { resourceName, migrationId, checksum, leaseOwner, heldFence,
                            statementCount, statementCount })
                end
                query([[INSERT INTO `synex_schema_migration_attempts`
                    (`resource_name`, `migration_id`, `checksum_sha256`, `state`, `attempts`,
                     `last_error_code`, `started_at`, `finished_at`)
                    VALUES (?, ?, ?, 'applied', 1, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))
                    ON DUPLICATE KEY UPDATE `state` = 'applied', `last_error_code` = NULL,
                        `finished_at` = CURRENT_TIMESTAMP(6)]], { resourceName, migrationId, checksum })
                return true, { execute = false }
            end

            if ownedFence then
                if ownedFence.state == 'applying' or ownedFence.state == 'failed'
                    or ownedFence.state == 'indeterminate' then
                    return false, nil, migrationError('MIGRATION_INDETERMINATE',
                        ('Migration %s/%s has an unresolved fenced attempt and will not be reclaimed automatically.')
                            :format(resourceName, migrationId))
                end
                if ownedFence.state == 'applied' then
                    return false, nil, migrationError('MIGRATION_STATE_INCONSISTENT',
                        ('Migration %s/%s has a completed fence but no applied marker.'):format(
                            resourceName, migrationId))
                end
                return false, nil, migrationError('MIGRATION_STATE_INCONSISTENT',
                    ('Migration %s/%s has an unsupported fence state.'):format(resourceName, migrationId))
            end

            if attempt then
                query([[INSERT INTO `synex_schema_migration_fences`
                    (`resource_name`, `migration_id`, `checksum_sha256`, `owner_id`, `fencing_token`,
                     `state`, `statement_count`, `completed_statements`, `last_error_code`,
                     `started_at`, `finished_at`)
                    VALUES (?, ?, ?, ?, ?, 'indeterminate', ?, 0, 'LEGACY_ATTEMPT',
                        CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))]],
                    { resourceName, migrationId, checksum, leaseOwner, heldFence, statementCount })
                return true, {
                    error = migrationError('MIGRATION_INDETERMINATE',
                        ('Legacy migration attempt %s/%s is unresolved and will not be reclaimed automatically.')
                            :format(resourceName, migrationId))
                }
            end

            query([[INSERT INTO `synex_schema_migration_fences`
                (`resource_name`, `migration_id`, `checksum_sha256`, `owner_id`, `fencing_token`,
                 `state`, `statement_count`, `completed_statements`, `last_error_code`,
                 `started_at`, `finished_at`)
                VALUES (?, ?, ?, ?, ?, 'applying', ?, 0, NULL, CURRENT_TIMESTAMP(6), NULL)]],
                { resourceName, migrationId, checksum, leaseOwner, heldFence, statementCount })
            query([[INSERT INTO `synex_schema_migration_attempts`
                (`resource_name`, `migration_id`, `checksum_sha256`, `state`, `attempts`,
                 `last_error_code`, `started_at`, `finished_at`)
                VALUES (?, ?, ?, 'applying', 1, NULL, CURRENT_TIMESTAMP(6), NULL)]],
                { resourceName, migrationId, checksum })
            return true, { execute = true }
        end)
    end

    local function advanceMigrationFence(resourceName, migrationId, checksum, statementIndex)
        return withCurrentMigrationLease(function(query, heldFence)
            local rows = query([[SELECT `owner_id`, `fencing_token`, `state`, `checksum_sha256`,
                    `completed_statements`, `statement_count`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local row = rows[1]
            if not row or row.owner_id ~= leaseOwner or tonumber(row.fencing_token) ~= heldFence
                or row.state ~= 'applying' or row.checksum_sha256 ~= checksum
                or tonumber(row.completed_statements) ~= statementIndex - 1
                or statementIndex > (tonumber(row.statement_count) or -1) then
                return false, nil, migrationError('MIGRATION_FENCE_LOST',
                    ('Migration statement fence for %s/%s is no longer current.'):format(
                        resourceName, migrationId))
            end
            query([[UPDATE `synex_schema_migration_fences`
                SET `completed_statements` = ?
                WHERE `resource_name` = ? AND `migration_id` = ? AND `owner_id` = ?
                    AND `fencing_token` = ? AND `state` = 'applying'
                    AND `checksum_sha256` = ? AND `completed_statements` = ?]],
                { statementIndex, resourceName, migrationId, leaseOwner, heldFence,
                    checksum, statementIndex - 1 })
            local advancedRows = query([[SELECT `completed_statements`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? AND `owner_id` = ?
                    AND `fencing_token` = ? AND `state` = 'applying'
                    AND `checksum_sha256` = ? FOR UPDATE]],
                { resourceName, migrationId, leaseOwner, heldFence, checksum }) or {}
            if not advancedRows[1]
                or tonumber(advancedRows[1].completed_statements) ~= statementIndex then
                return false, nil, migrationError('MIGRATION_FENCE_LOST',
                    ('Migration statement fence for %s/%s did not advance atomically.'):format(
                        resourceName, migrationId))
            end
            return true
        end)
    end

    local function markMigrationIndeterminate(resourceName, migrationId, checksum, causeCode)
        return withCurrentMigrationLease(function(query, heldFence)
            local rows = query([[SELECT `owner_id`, `fencing_token`, `state`, `checksum_sha256`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local row = rows[1]
            if not row or row.owner_id ~= leaseOwner or tonumber(row.fencing_token) ~= heldFence
                or row.state ~= 'applying' or row.checksum_sha256 ~= checksum then
                return false, nil, migrationError('MIGRATION_FENCE_LOST',
                    ('Migration failure fence for %s/%s is no longer current.'):format(
                        resourceName, migrationId))
            end
            query([[UPDATE `synex_schema_migration_fences`
                SET `state` = 'indeterminate', `last_error_code` = ?,
                    `finished_at` = CURRENT_TIMESTAMP(6)
                WHERE `resource_name` = ? AND `migration_id` = ? AND `owner_id` = ?
                    AND `fencing_token` = ? AND `state` = 'applying' AND `checksum_sha256` = ?]],
                { causeCode, resourceName, migrationId, leaseOwner, heldFence, checksum })
            return true
        end)
    end

    local function finalizeMigration(resourceName, migrationId, checksum, statementCount, durationMs)
        return withCurrentMigrationLease(function(query, heldFence)
            local rows = query([[SELECT `owner_id`, `fencing_token`, `state`, `checksum_sha256`,
                    `statement_count`, `completed_statements`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local row = rows[1]
            if not row or row.owner_id ~= leaseOwner or tonumber(row.fencing_token) ~= heldFence
                or row.state ~= 'applying' or row.checksum_sha256 ~= checksum
                or tonumber(row.statement_count) ~= statementCount
                or tonumber(row.completed_statements) ~= statementCount then
                return false, nil, migrationError('MIGRATION_FENCE_LOST',
                    ('Migration completion fence for %s/%s is no longer current.'):format(
                        resourceName, migrationId))
            end
            query([[INSERT INTO `synex_schema_migrations`
                (`migration_id`, `resource_name`, `checksum_sha256`, `duration_ms`, `instance_id`)
                VALUES (?, ?, ?, ?, ?)]],
                { migrationId, resourceName, checksum, durationMs, leaseOwner })
            query([[UPDATE `synex_schema_migration_fences`
                SET `state` = 'applied', `last_error_code` = NULL,
                    `finished_at` = CURRENT_TIMESTAMP(6)
                WHERE `resource_name` = ? AND `migration_id` = ? AND `owner_id` = ?
                    AND `fencing_token` = ? AND `state` = 'applying' AND `checksum_sha256` = ?]],
                { resourceName, migrationId, leaseOwner, heldFence, checksum })
            query([[UPDATE `synex_schema_migration_attempts`
                SET `state` = 'applied', `last_error_code` = NULL,
                    `finished_at` = CURRENT_TIMESTAMP(6)
                WHERE `resource_name` = ? AND `migration_id` = ?
                    AND `checksum_sha256` = ? AND `state` = 'applying']],
                { resourceName, migrationId, checksum })
            local markerRows = query([[SELECT `checksum_sha256`, `instance_id`
                FROM `synex_schema_migrations`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local completedRows = query([[SELECT `owner_id`, `fencing_token`, `state`
                FROM `synex_schema_migration_fences`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local attemptRows = query([[SELECT `state`, `checksum_sha256`
                FROM `synex_schema_migration_attempts`
                WHERE `resource_name` = ? AND `migration_id` = ? FOR UPDATE]],
                { resourceName, migrationId }) or {}
            local marker, completed, attempt = markerRows[1], completedRows[1], attemptRows[1]
            if not marker or marker.checksum_sha256 ~= checksum or marker.instance_id ~= leaseOwner
                or not completed or completed.owner_id ~= leaseOwner
                or tonumber(completed.fencing_token) ~= heldFence or completed.state ~= 'applied'
                or not attempt or attempt.state ~= 'applied' or attempt.checksum_sha256 ~= checksum then
                return false, nil, migrationError('MIGRATION_MARKER_WRITE_FAILED',
                    ('Migration completion markers for %s/%s were not atomically persisted.'):format(
                        resourceName, migrationId))
            end
            return true
        end)
    end

    local function startMigrationHeartbeat(manager)
        local heartbeat = { active = true }
        if type(platform.createThread) ~= 'function' then return heartbeat end
        local intervalMs = math.max(1000, math.min(10000, math.floor(leaseSeconds * 1000 / 3)))
        platform.createThread(function()
            while heartbeat.active do
                platform.wait(intervalMs)
                if not heartbeat.active then break end
                local renewed, heartbeatError = manager:renewLease()
                if not renewed then
                    heartbeat.error = heartbeatError
                    heartbeat.active = false
                    break
                end
                metrics:increment('synex_migration_lease_heartbeats_total', { ok = true })
            end
            if heartbeat.error then
                metrics:increment('synex_migration_lease_heartbeats_total', { ok = false })
            end
        end)
        return heartbeat
    end

    function migrationManager:apply(resourceName, migrations)
        for _, migration in ipairs(migrations or {}) do
            local contents = platform.loadResourceFile(resourceName, migration.path)
            if not contents then
                return nil, migrationError('MIGRATION_NOT_FOUND',
                    ('Migration %s is missing.'):format(migration.path))
            end
            local statements = splitStatements(contents)
            if #statements < 1 or #statements > 65535 then
                return nil, migrationError('MIGRATION_STATEMENT_COUNT_INVALID',
                    ('Migration %s/%s must contain between 1 and 65535 statements.'):format(
                        resourceName, migration.id))
            end
            local checksum = sha256(contents:gsub('\r\n', '\n'))
            local claim, claimError = claimMigration(resourceName, migration.id, checksum, #statements)
            if not claim then return nil, claimError end
            if claim.error then return nil, claim.error end
            if claim.execute then
                local started = foundation.monotonicMs()
                local heartbeat = startMigrationHeartbeat(self)
                for statementIndex, statement in ipairs(statements) do
                    local renewed, renewError = self:renewLease()
                    if not renewed then
                        heartbeat.active = false
                        return nil, renewError
                    end
                    local _, statementError = database:update(statement, {})
                    if statementError then
                        heartbeat.active = false
                        local causeCode = type(statementError.code) == 'string'
                            and statementError.code:sub(1, 64) or 'DATABASE_ERROR'
                        local marked, markerError = markMigrationIndeterminate(
                            resourceName, migration.id, checksum, causeCode)
                        if not marked then
                            logger:error('migration indeterminate marker write failed', {
                                resource = resourceName, migration = migration.id,
                                primaryCode = causeCode, code = markerError and markerError.code
                            })
                        end
                        return nil, migrationError('MIGRATION_INDETERMINATE',
                            ('Migration statement %d for %s/%s returned without a provable outcome.')
                                :format(statementIndex, resourceName, migration.id), {
                                details = { causeCode = causeCode, statementIndex = statementIndex }
                            })
                    end
                    renewed, renewError = self:renewLease()
                    if not renewed then
                        heartbeat.active = false
                        return nil, renewError
                    end
                    local advanced, advanceError = advanceMigrationFence(
                        resourceName, migration.id, checksum, statementIndex)
                    if not advanced then
                        heartbeat.active = false
                        return nil, advanceError
                    end
                end
                heartbeat.active = false
                local durationMs = math.max(0, math.min(0xffffffff,
                    foundation.monotonicMs() - started))
                local finalized, finalizeError = finalizeMigration(
                    resourceName, migration.id, checksum, #statements, durationMs)
                if not finalized then return nil, finalizeError end
                logger:info('migration applied', {
                    resource = resourceName, migration = migration.id, checksum = checksum
                })
            end
        end
        return true, nil
    end

    local terminalLeaseStates = {
        saga = { completed = true, failed = true, cancelled = true },
        character = { completed = true, failed = true, cancelled = true }
    }
    local function durableLeaseDomain(name)
        if name:sub(1, 5) == 'saga:' then
            local domainId = name:sub(6)
            if #domainId >= 1 and #domainId <= 36
                and domainId:match('^[a-z0-9_]+$') then
                return 'saga', domainId
            end
            return false, nil
        end
        if name:sub(1, 17) == 'character-delete:' then
            local domainId = name:sub(18)
            if #domainId >= 1 and #domainId <= 36
                and domainId:match('^[a-z0-9_]+$') then
                return 'character', domainId
            end
            return false, nil
        end
        return nil, nil
    end

    local leases = {}
    local nextAuthorityRecoveryKind = 'session'
    local leaseCapacityKinds = { 'admission', 'character', 'other', 'saga', 'session' }
    local leaseCapacityKindSet = {
        admission = true, character = true, other = true, saga = true, session = true
    }
    local leaseCapacityHighWatermarks = {
        global = 0, admission = 0, character = 0, other = 0, saga = 0, session = 0
    }
    local function leaseCapacityKind(name)
        if name == 'schema_migrations' then return nil end
        if name:sub(1, 8) == 'session:' then return 'session' end
        if name:sub(1, 10) == 'admission:' then return 'admission' end
        if name:sub(1, 5) == 'saga:' then return 'saga' end
        if name:sub(1, 17) == 'character-delete:' then return 'character' end
        return 'other'
    end
    local function leaseCapacityInteger(value, minimum)
        local parsed = tonumber(value)
        if not parsed or math.type(parsed) ~= 'integer'
            or parsed < minimum or parsed > 4294967295 then return nil end
        return parsed
    end
    local function leaseStorageText(value, maximum)
        if type(value) ~= 'string' or #value < 1 or #value > maximum then return false end
        for index = 1, #value do
            local byte = value:byte(index)
            if byte < 33 or byte > 126 then return false end
        end
        return true
    end
    local function leaseAffectedRows(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end
    local function emitLeaseCapacityMetrics(snapshot)
        if type(snapshot) ~= 'table' then return end
        local function emit(scope, current, limit)
            if type(current) ~= 'number' or type(limit) ~= 'number' or limit <= 0 then return end
            local utilization = current / limit
            metrics:gauge('synex_cluster_lease_capacity_entries', { scope = scope }, current)
            metrics:gauge('synex_cluster_lease_capacity_limit', { scope = scope }, limit)
            metrics:gauge('synex_cluster_lease_capacity_utilization', { scope = scope }, utilization)
            leaseCapacityHighWatermarks[scope] = math.max(
                leaseCapacityHighWatermarks[scope], utilization)
            metrics:gauge('synex_cluster_lease_capacity_utilization_high_watermark',
                { scope = scope }, leaseCapacityHighWatermarks[scope])
        end
        local global = snapshot.global
        if type(global) == 'table' then emit('global', global.current, global.limit) end
        for _, kind in ipairs(leaseCapacityKinds) do
            local value = snapshot.kinds and snapshot.kinds[kind] or nil
            if type(value) == 'table' then emit(kind, value.current, value.limit) end
        end
    end
    function leases:acquire(name, owner, ttlSeconds, requesterInstanceId, requesterBootId)
        if not leaseStorageText(name, 96) or not leaseStorageText(owner, 96) then
            return nil, foundation.error('INVALID_LEASE', 'Lease name or owner is invalid.')
        end
        local requesterFenced = requesterInstanceId ~= nil or requesterBootId ~= nil
        local sessionLease = name:sub(1, 8) == 'session:'
        local admissionLease = name:sub(1, 10) == 'admission:'
        local domainKind, domainId = durableLeaseDomain(name)
        if domainKind == false then
            return nil, foundation.error('INVALID_LEASE',
                'The durable lease domain name is invalid.')
        end
        if (sessionLease or admissionLease or domainKind ~= nil) and not requesterFenced then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Durable domain leases require the current runtime boot authority.')
        end
        if requesterFenced and (type(requesterInstanceId) ~= 'string' or #requesterInstanceId < 1
            or #requesterInstanceId > 36
            or owner:sub(1, #requesterInstanceId + 1) ~= requesterInstanceId .. ':'
            or type(requesterBootId) ~= 'string' or #requesterBootId < 1 or #requesterBootId > 36
            or (type(runtimeInstanceId) == 'string' and requesterInstanceId ~= runtimeInstanceId)) then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Lease requester authority is invalid.')
        end
        ttlSeconds = math.max(5, math.min(tonumber(ttlSeconds) or 30, 300))
        local capacityKind = leaseCapacityKind(name)
        local acquiredFence, acquireError, capacitySnapshot = nil, nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            acquiredFence, acquireError, capacitySnapshot = nil, nil, nil
            if requesterFenced then
                local requester = query([[SELECT `status` FROM `synex_instances`
                    WHERE `instance_id` = ? AND `status` = 'ready' FOR UPDATE]],
                    { requesterInstanceId }) or {}
                if not requester[1] then
                    acquireError = foundation.error('LEASE_BUSY',
                        'The requester no longer owns ready runtime authority.', { retryable = true })
                    return false
                end
                local boot = query([[SELECT `boot_id` FROM `synex_instance_boots`
                    WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
                    { requesterInstanceId, requesterBootId }) or {}
                if not boot[1] then
                    acquireError = foundation.error('LEASE_BUSY',
                        'The requester boot generation is no longer current.', { retryable = true })
                    return false
                end
                if domainKind ~= nil then
                    local rows = nil
                    if domainKind == 'saga' then
                        rows = query([[SELECT `state` FROM `synex_sagas`
                            WHERE `public_id` = ? FOR UPDATE]], { domainId }) or {}
                    else
                        rows = query([[SELECT `state` FROM `synex_character_deletion_plans`
                            WHERE `id` = ? FOR UPDATE]], { domainId }) or {}
                    end
                    local domain = rows[1]
                    if not domain then
                        acquireError = foundation.error('LEASE_DOMAIN_NOT_FOUND',
                            'The durable lease domain does not exist.')
                        return false
                    end
                    if terminalLeaseStates[domainKind][domain.state] then
                        acquireError = foundation.error('LEASE_DOMAIN_TERMINAL',
                            'The durable lease domain is already terminal.')
                        return false
                    end
                end
            end
            local function lockExactLease()
                if capacityKind == nil then
                    return query([[SELECT `owner_id`, `fencing_token`,
                            (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                        FROM `synex_cluster_leases`
                        WHERE `lease_name` = ? FOR UPDATE]], { name }) or {}
                end
                return query([[SELECT `owner_id`, `fencing_token`, `lease_capacity_kind`,
                        (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                    FROM `synex_cluster_leases`
                    WHERE `lease_name` = ? FOR UPDATE]], { name }) or {}
            end
            local rows = lockExactLease()
            if #rows > 1 then
                acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                    'The exact cluster lease identity is not unique.', { retryable = true })
                return false
            end
            local row = rows[1]
            local created = false
            if not row then
                local inserted = query([[INSERT IGNORE INTO `synex_cluster_leases`
                    (`lease_name`, `owner_id`, `fencing_token`, `expires_at`)
                    VALUES (?, ?, 1, TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
                    { name, owner, ttlSeconds })
                local insertedRows = leaseAffectedRows(inserted)
                if insertedRows == 1 then
                    created = true
                    row = {
                        owner_id = owner, fencing_token = 1, valid = 1,
                        lease_capacity_kind = capacityKind
                    }
                elseif insertedRows == 0 then
                    rows = lockExactLease()
                    if #rows ~= 1 then
                        acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                            'A contended cluster lease identity could not be locked exactly.', {
                                retryable = true
                            })
                        return false
                    end
                    row = rows[1]
                else
                    acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                        'The cluster lease identity reservation returned an invalid result.', {
                            retryable = true
                        })
                    return false
                end
            end
            if row and capacityKind ~= nil and row.lease_capacity_kind ~= capacityKind then
                acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                    'The persisted cluster lease kind is invalid.', { retryable = true })
                return false
            end
            if not created then
                local fenceValue = tonumber(row.fencing_token)
                if not fenceValue or fenceValue < 1 then
                    acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                        'The persisted cluster lease fence is invalid.', { retryable = true })
                    return false
                end
                if tonumber(row.valid) == 1 and row.owner_id ~= owner then
                    acquireError = foundation.error('LEASE_BUSY',
                        'The lease is held by another server instance.', { retryable = true })
                    return false
                end
                local updated = query([[UPDATE `synex_cluster_leases`
                    SET `terminal_compaction_at` = IF(
                            (? = 1 OR ? = 1), NULL, `terminal_compaction_at`),
                        `owner_id` = ?, `fencing_token` = `fencing_token` + 1,
                        `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                    WHERE `lease_name` = ?
                        AND (`expires_at` <= CURRENT_TIMESTAMP(6) OR `owner_id` = ?)]],
                    { sessionLease and 1 or 0, admissionLease and 1 or 0,
                        owner, ttlSeconds, name, owner })
                if leaseAffectedRows(updated) ~= 1 then
                    acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                        'The existing cluster lease changed unexpectedly.', { retryable = true })
                    return false
                end
            elseif capacityKind ~= nil then
                local globalRows = query([[SELECT `entry_count`, `global_limit`
                        FROM `synex_cluster_lease_capacity`
                        WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
                    local global = globalRows[1]
                    local globalCount = global and leaseCapacityInteger(global.entry_count, 0) or nil
                    local globalLimit = global and leaseCapacityInteger(global.global_limit, 1) or nil
                    if #globalRows ~= 1 or not globalCount or not globalLimit then
                        acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                            'The global cluster lease capacity authority is missing or invalid.', {
                                retryable = true
                            })
                        return false
                    end
                    local kindRows = query([[SELECT `lease_capacity_kind`, `entry_count`, `kind_limit`
                        FROM `synex_cluster_lease_kind_capacity`
                        WHERE `lease_capacity_kind` = ? FOR UPDATE]], { capacityKind }) or {}
                    local kindRow = kindRows[1]
                    local kindCount = kindRow and leaseCapacityInteger(kindRow.entry_count, 0) or nil
                    local kindLimit = kindRow and leaseCapacityInteger(kindRow.kind_limit, 1) or nil
                    if #kindRows ~= 1 or not kindRow
                        or kindRow.lease_capacity_kind ~= capacityKind
                        or not kindCount or not kindLimit or kindLimit > globalLimit
                        or kindCount > globalCount then
                        acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                            'The cluster lease kind capacity authority is missing or invalid.', {
                                retryable = true
                            })
                        return false
                    end
                    capacitySnapshot = {
                        global = { current = globalCount, limit = globalLimit },
                        kinds = {
                            [capacityKind] = { current = kindCount, limit = kindLimit }
                        }
                    }
                    local deniedScope = globalCount >= globalLimit and 'global'
                        or kindCount >= kindLimit and capacityKind or nil
                    if deniedScope then
                        acquireError = foundation.error('LEASE_CAPACITY_EXCEEDED',
                            'Persistent cluster lease capacity is exhausted for this scope.', {
                                retryable = true, details = { scope = deniedScope }
                            })
                        return false
                    end
                    local globalUpdated = query([[UPDATE `synex_cluster_lease_capacity`
                        SET `entry_count` = `entry_count` + 1
                        WHERE `singleton_id` = 1 AND `entry_count` = ?
                            AND `entry_count` < `global_limit`
                            AND `entry_count` < 4294967295]], { globalCount })
                    if leaseAffectedRows(globalUpdated) ~= 1 then
                        acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                            'The global cluster lease counter changed unexpectedly.', {
                                retryable = true
                            })
                        return false
                    end
                    local kindUpdated = query([[UPDATE `synex_cluster_lease_kind_capacity`
                        SET `entry_count` = `entry_count` + 1
                        WHERE `lease_capacity_kind` = ? AND `entry_count` = ?
                            AND `entry_count` < `kind_limit`
                            AND `entry_count` < 4294967295]], { capacityKind, kindCount })
                if leaseAffectedRows(kindUpdated) ~= 1 then
                    acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                        'The cluster lease kind counter changed unexpectedly.', {
                            retryable = true
                        })
                    return false
                end
            end
            local verifiedRows
            if capacityKind == nil then
                verifiedRows = query([[SELECT `owner_id`, `fencing_token`,
                        (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                    FROM `synex_cluster_leases`
                    WHERE `lease_name` = ? FOR UPDATE]], { name }) or {}
            else
                verifiedRows = query([[SELECT `owner_id`, `fencing_token`, `lease_capacity_kind`,
                        (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                    FROM `synex_cluster_leases`
                    WHERE `lease_name` = ? FOR UPDATE]], { name }) or {}
            end
            local verified = verifiedRows[1]
            acquiredFence = verified and tonumber(verified.fencing_token) or nil
            if #verifiedRows ~= 1 or not acquiredFence or acquiredFence < 1
                or verified.owner_id ~= owner or tonumber(verified.valid) ~= 1
                or (capacityKind ~= nil and verified.lease_capacity_kind ~= capacityKind) then
                acquireError = foundation.error('LEASE_CAPACITY_INVALID',
                    'The acquired cluster lease could not be verified exactly.', {
                        retryable = true
                    })
                return false
            end
            if created and capacityKind ~= nil then
                capacitySnapshot.global.current = capacitySnapshot.global.current + 1
                capacitySnapshot.kinds[capacityKind].current
                    = capacitySnapshot.kinds[capacityKind].current + 1
            end
            return true
        end)
        emitLeaseCapacityMetrics(capacitySnapshot)
        if not committed then
            if acquireError and acquireError.code == 'LEASE_CAPACITY_EXCEEDED' then
                metrics:increment('synex_cluster_lease_capacity_denials_total', {
                    scope = acquireError.details.scope
                })
            elseif acquireError and acquireError.code == 'LEASE_CAPACITY_INVALID' then
                metrics:increment('synex_cluster_lease_capacity_denials_total', {
                    scope = 'integrity'
                })
            end
            return nil, acquireError or transactionError
        end
        return {
            name = name, owner = owner, fencingToken = acquiredFence, ttlSeconds = ttlSeconds,
            requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId
        }, nil
    end
    function leases:renew(lease)
        if type(lease) ~= 'table' then return nil, foundation.error('INVALID_LEASE', 'Lease snapshot is invalid.') end
        local requesterFenced = lease.requesterInstanceId ~= nil or lease.requesterBootId ~= nil
        local leaseName = lease.name or lease.leaseName
        local domainKind = nil
        if type(leaseName) == 'string' then domainKind = durableLeaseDomain(leaseName) end
        if domainKind == false then
            return nil, foundation.error('INVALID_LEASE',
                'The durable lease domain name is invalid.')
        end
        if type(leaseName) == 'string'
            and (leaseName:sub(1, 8) == 'session:'
                or leaseName:sub(1, 10) == 'admission:' or domainKind ~= nil)
            and not requesterFenced then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Durable lease renewal requires the current runtime boot authority.')
        end
        if requesterFenced and (type(lease.requesterInstanceId) ~= 'string'
            or #lease.requesterInstanceId < 1 or #lease.requesterInstanceId > 36
            or type(lease.requesterBootId) ~= 'string'
            or #lease.requesterBootId < 1 or #lease.requesterBootId > 36) then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Lease renewal authority is invalid.')
        end
        if requesterFenced then
            local authorityError = nil
            local committed, transactionError = database:withTransaction(function(query)
                local requester = query([[SELECT `status` FROM `synex_instances`
                    WHERE `instance_id` = ? AND `status` IN ('ready', 'degraded') FOR UPDATE]],
                    { lease.requesterInstanceId }) or {}
                local boot = requester[1] and (query([[SELECT `boot_id` FROM `synex_instance_boots`
                    WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
                    { lease.requesterInstanceId, lease.requesterBootId }) or {}) or {}
                local rows = boot[1] and (query([[SELECT `owner_id`, `fencing_token`,
                        (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                    FROM `synex_cluster_leases` WHERE `lease_name` = ? FOR UPDATE]],
                    { leaseName }) or {}) or {}
                local row = rows[1]
                if not requester[1] or not boot[1] or not row or row.owner_id ~= lease.owner
                    or tonumber(row.fencing_token) ~= lease.fencingToken or tonumber(row.valid) ~= 1 then
                    authorityError = foundation.error('LEASE_LOST',
                        'The cluster lease or requester boot fence is stale.', { retryable = true })
                    return false
                end
                query([[UPDATE `synex_cluster_leases`
                    SET `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
                    WHERE `lease_name` = ?]], { lease.ttlSeconds, leaseName })
                return true
            end)
            if not committed then return nil, authorityError or transactionError end
            return true, nil
        end
        local affected, err = database:update([[UPDATE `synex_cluster_leases`
            SET `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
            WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?
                AND `expires_at` > CURRENT_TIMESTAMP(6)]],
            { lease.ttlSeconds, lease.name, lease.owner, lease.fencingToken })
        if err then return nil, err end
        if tonumber(affected) ~= 1 then return nil, foundation.error('LEASE_LOST', 'The cluster lease fencing token is stale.', { retryable = true }) end
        return true, nil
    end
    function leases:release(lease)
        if type(lease) ~= 'table' then return false, nil end
        local name = lease.name or lease.leaseName
        local compactable = type(name) == 'string'
            and (name:sub(1, 8) == 'session:' or name:sub(1, 10) == 'admission:')
        local affected, err
        if compactable then
            affected, err = database:update([[UPDATE `synex_cluster_leases`
                SET `owner_id` = 'retired',
                    `fencing_token` = CASE
                        WHEN `fencing_token` < 18446744073709551615
                            THEN `fencing_token` + 1
                        ELSE `fencing_token`
                    END,
                    `expires_at` = CURRENT_TIMESTAMP(6),
                    `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?]],
                { name, lease.owner, lease.fencingToken })
        else
            affected, err = database:update([[UPDATE `synex_cluster_leases`
                SET `expires_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?]],
                { name, lease.owner, lease.fencingToken })
        end
        if err then return nil, err end
        if compactable and tonumber(affected) ~= 1 then
            return nil, foundation.error('LEASE_LOST',
                'The released session or admission lease is stale.', { retryable = true })
        end
        return true, nil
    end
    function leases:retireExpiredAuthority(maximum)
        maximum = maximum == nil and 250 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 1000 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Expired authority retirement batch size must be an integer from 1 through 1000.')
        end
        local kind = nextAuthorityRecoveryKind
        local selected, retired = 0, 0
        local retirementError = nil
        local committed, transactionError = database:withTransaction(function(query)
            retirementError = nil
            local rows = query([[SELECT `lease_name`
                FROM `synex_cluster_leases`
                    FORCE INDEX (`idx_cluster_leases_authority_expiry`)
                WHERE `lease_authority_kind` = ? AND `terminal_compaction_at` IS NULL
                    AND `expires_at` <= CURRENT_TIMESTAMP(6)
                ORDER BY `expires_at` ASC, `lease_name` ASC LIMIT ? FOR UPDATE]], {
                kind, maximum
            }) or {}
            if type(rows) ~= 'table' or #rows > maximum then
                retirementError = foundation.error('DATABASE_RESULT_INVALID',
                    'Expired authority retirement returned an invalid candidate batch.', {
                        retryable = true
                    })
                return false
            end
            selected = #rows
            if selected == 0 then return true end
            local names, placeholders, seen = {}, {}, {}
            for index, row in ipairs(rows) do
                local name = type(row) == 'table' and row.lease_name or nil
                local prefix = kind == 'session' and 'session:' or 'admission:'
                if type(name) ~= 'string' or #name <= #prefix or #name > 96
                    or name:sub(1, #prefix) ~= prefix or seen[name] then
                    retirementError = foundation.error('DATABASE_RESULT_INVALID',
                        'Expired authority retirement returned an invalid lease identity.', {
                            retryable = true
                        })
                    return false
                end
                seen[name] = true
                names[index], placeholders[index] = name, '?'
            end
            local parameters = { kind }
            for _, name in ipairs(names) do parameters[#parameters + 1] = name end
            local updated = query([[UPDATE `synex_cluster_leases`
                SET `owner_id` = 'retired',
                    `fencing_token` = CASE
                        WHEN `fencing_token` < 18446744073709551615
                            THEN `fencing_token` + 1
                        ELSE `fencing_token`
                    END,
                    `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_authority_kind` = ? AND `terminal_compaction_at` IS NULL
                    AND `expires_at` <= CURRENT_TIMESTAMP(6)
                    AND `lease_name` IN (]] .. table.concat(placeholders, ',') .. ')', parameters)
            retired = type(updated) == 'table' and tonumber(updated.affectedRows)
                or tonumber(updated)
            if not retired or math.type(retired) ~= 'integer' or retired ~= selected then
                retirementError = foundation.error('DATABASE_RESULT_INVALID',
                    'Expired authority retirement did not match the locked candidate batch.', {
                        retryable = true
                    })
                return false
            end
            return true
        end)
        if not committed then return nil, retirementError or transactionError end
        nextAuthorityRecoveryKind = kind == 'session' and 'admission' or 'session'
        metrics:increment('synex_cluster_lease_retirement_total', {
            kind = kind, result = 'complete'
        }, retired)
        return { kind = kind, selected = selected, retired = retired, maximum = maximum }, nil
    end
    function leases:compactTerminal(maximum)
        maximum = maximum == nil and 250 or maximum
        if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 1000 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Terminal lease compaction batch size must be an integer from 1 through 1000.')
        end
        local report = { selected = 0, deleted = 0, maximum = maximum }
        local compactionError, capacitySnapshot = nil, nil
        local committed, transactionError = database:withTransaction(function(query)
            report.selected, report.deleted = 0, 0
            compactionError, capacitySnapshot = nil, nil
            local rows = query([[SELECT `lease_name`, `lease_capacity_kind`
                FROM `synex_cluster_leases`
                    FORCE INDEX (`idx_cluster_leases_terminal_compaction`)
                WHERE `terminal_compaction_at` <= CURRENT_TIMESTAMP(6)
                    AND `lease_capacity_kind` IS NOT NULL
                    AND `lease_name` <> 'schema_migrations'
                ORDER BY `terminal_compaction_at` ASC, `lease_name` ASC
                LIMIT ? FOR UPDATE]], { maximum }) or {}
            if type(rows) ~= 'table' or #rows > maximum then
                compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                    'Terminal lease compaction returned an invalid candidate batch.', {
                        retryable = true
                    })
                return false
            end
            report.selected = #rows
            if #rows == 0 then return true end

            local names, placeholders, seen = {}, {}, {}
            local kindReleaseCounts, kinds = {}, {}
            for index, row in ipairs(rows) do
                local name = type(row) == 'table' and row.lease_name or nil
                local kind = type(row) == 'table' and row.lease_capacity_kind or nil
                if type(name) ~= 'string' or #name < 1 or #name > 96
                    or name == 'schema_migrations' or seen[name]
                    or not leaseCapacityKindSet[kind] or leaseCapacityKind(name) ~= kind then
                    compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                        'Terminal lease compaction returned invalid capacity authority.', {
                            retryable = true
                        })
                    return false
                end
                seen[name] = true
                names[index], placeholders[index] = name, '?'
                if kindReleaseCounts[kind] == nil then
                    kindReleaseCounts[kind] = 0
                    kinds[#kinds + 1] = kind
                end
                kindReleaseCounts[kind] = kindReleaseCounts[kind] + 1
            end
            table.sort(kinds)

            local globalRows = query([[SELECT `entry_count`, `global_limit`
                FROM `synex_cluster_lease_capacity`
                WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
            local global = globalRows[1]
            local globalCount = global and leaseCapacityInteger(global.entry_count, 0) or nil
            local globalLimit = global and leaseCapacityInteger(global.global_limit, 1) or nil
            if #globalRows ~= 1 or not globalCount or not globalLimit
                or globalCount < #rows then
                compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                    'The global cluster lease counter cannot release the locked batch.', {
                        retryable = true
                    })
                return false
            end

            local kindValues, lockedKindTotal = {}, 0
            capacitySnapshot = {
                global = { current = globalCount, limit = globalLimit }, kinds = {}
            }
            for _, kind in ipairs(kinds) do
                local kindRows = query([[SELECT `lease_capacity_kind`, `entry_count`, `kind_limit`
                    FROM `synex_cluster_lease_kind_capacity`
                    WHERE `lease_capacity_kind` = ? FOR UPDATE]], { kind }) or {}
                local kindRow = kindRows[1]
                local count = kindRow and leaseCapacityInteger(kindRow.entry_count, 0) or nil
                local limit = kindRow and leaseCapacityInteger(kindRow.kind_limit, 1) or nil
                local releaseCount = kindReleaseCounts[kind]
                if #kindRows ~= 1 or not kindRow or kindRow.lease_capacity_kind ~= kind
                    or not count or not limit or limit > globalLimit
                    or not releaseCount or count < releaseCount then
                    compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                        'A cluster lease kind counter cannot release its locked rows.', {
                            retryable = true
                        })
                    return false
                end
                kindValues[kind] = { current = count, limit = limit }
                capacitySnapshot.kinds[kind] = { current = count, limit = limit }
                lockedKindTotal = lockedKindTotal + count
            end
            if lockedKindTotal > globalCount then
                compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                    'Cluster lease kind counters exceed global retained capacity.', {
                        retryable = true
                    })
                return false
            end

            local deleted = query([[DELETE FROM `synex_cluster_leases`
                WHERE `lease_name` IN (]] .. table.concat(placeholders, ',') .. [[)
                    AND `terminal_compaction_at` <= CURRENT_TIMESTAMP(6)
                    AND `lease_capacity_kind` IS NOT NULL
                    AND `lease_name` <> 'schema_migrations']], names)
            if leaseAffectedRows(deleted) ~= #rows then
                compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                    'Terminal cluster leases changed during exact deletion.', {
                        retryable = true
                    })
                return false
            end

            local globalUpdated = query([[UPDATE `synex_cluster_lease_capacity`
                SET `entry_count` = `entry_count` - ?
                WHERE `singleton_id` = 1 AND `entry_count` = ? AND `entry_count` >= ?]],
                { #rows, globalCount, #rows })
            if leaseAffectedRows(globalUpdated) ~= 1 then
                compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                    'The global cluster lease counter changed during release.', {
                        retryable = true
                    })
                return false
            end
            for _, kind in ipairs(kinds) do
                local value = kindValues[kind]
                local releaseCount = kindReleaseCounts[kind]
                local kindUpdated = query([[UPDATE `synex_cluster_lease_kind_capacity`
                    SET `entry_count` = `entry_count` - ?
                    WHERE `lease_capacity_kind` = ? AND `entry_count` = ?
                        AND `entry_count` >= ?]],
                    { releaseCount, kind, value.current, releaseCount })
                if leaseAffectedRows(kindUpdated) ~= 1 then
                    compactionError = foundation.error('LEASE_CAPACITY_INVALID',
                        'A cluster lease kind counter changed during release.', {
                            retryable = true
                        })
                    return false
                end
                capacitySnapshot.kinds[kind].current = value.current - releaseCount
            end
            capacitySnapshot.global.current = globalCount - #rows
            report.deleted = #rows
            return true
        end)
        emitLeaseCapacityMetrics(capacitySnapshot)
        if not committed then
            metrics:increment('synex_cluster_lease_capacity_denials_total', {
                scope = 'integrity'
            })
            metrics:increment('synex_cluster_lease_compaction_total', { result = 'failed' })
            return nil, compactionError or transactionError
        end
        metrics:increment('synex_cluster_lease_compaction_total', {
            result = 'complete'
        }, report.deleted)
        return report, nil
    end

    return {
        database = database,
        migrations = migrationManager,
        leases = leases,
        sha256 = sha256,
        splitStatements = splitStatements
    }
end
