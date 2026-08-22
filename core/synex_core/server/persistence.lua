local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.persistence = function(deps)
    local platform = assert(deps.platform, 'persistence requires platform')
    local foundation = assert(deps.foundation, 'persistence requires foundation')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local config = deps.config or {}
    local runtimeInstanceId = deps.instanceId

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
    local function failureDetails(value)
        if type(value) == 'table' then
            return tostring(value.code or value.errno or value.sqlState or value.sqlstate or value.message or '')
        end
        return tostring(value or '')
    end
    local function isRetryableDeadlock(value)
        local detail = failureDetails(value):lower()
        return detail:find('1213', 1, true) ~= nil
            or detail:find('40001', 1, true) ~= nil
            or detail:find('deadlock', 1, true) ~= nil
    end
    local function attribution()
        local context = foundation.currentContext and foundation.currentContext() or nil
        return {
            resource = context and (context.provider or context.caller) or 'synex_core',
            operation = context and (context.contract or context.service or context.hook) or 'kernel',
            traceId = context and context.traceId or nil
        }
    end
    local function measured(kind, sql, parameters)
        local started = foundation.monotonicMs()
        local ok, value, adapterError = foundation.safeCall(adapter[kind], sql, parameters or {})
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
            logger:warn('slow database operation', {
                kind = kind, durationMs = duration, statementHash = sha256(sql),
                resource = attributed.resource, operation = attributed.operation, traceId = attributed.traceId
            })
        end
        if not ok or adapterError ~= nil then
            local failure = ok and adapterError or value
            logger:error('database operation failed', {
                kind = kind, statementHash = sha256(sql), error = failureDetails(failure),
                resource = attributed.resource, operation = attributed.operation, traceId = attributed.traceId
            })
            return nil, foundation.error('DATABASE_ERROR', 'The database operation failed.', {
                retryable = isRetryableDeadlock(failure)
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
            local started = foundation.monotonicMs()
            local ok, result, adapterError = foundation.safeCall(adapter.transaction, statements)
            local duration = foundation.monotonicMs() - started
            local failure = ok and adapterError or result
            metrics:increment('synex_db_transactions_total', { ok = ok and result == true, attempt = attempt })
            if ok and result == true then return true, nil end
            local deadlock = isRetryableDeadlock(failure)
            if deadlock and attempt < maximumAttempts then
                metrics:increment('synex_db_deadlock_retries_total', { kind = 'batch' })
                platform.wait(math.min(100, attempt * 10))
            else
                logger:error('database transaction failed', { durationMs = duration, error = failureDetails(failure), attempt = attempt })
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
            local started = foundation.monotonicMs()
            local ok, result, adapterError = foundation.safeCall(adapter.startTransaction, handler)
            local duration = foundation.monotonicMs() - started
            local failure = ok and adapterError or result
            metrics:increment('synex_db_interactive_transactions_total', { ok = ok and result == true, attempt = attempt })
            if duration >= 25000 then logger:warn('interactive transaction approached the oxmysql hard timeout', { durationMs = duration }) end
            if ok and result == true then return true, nil end
            local deadlock = isRetryableDeadlock(failure)
            if deadlock and attempt < maximumAttempts then
                metrics:increment('synex_db_deadlock_retries_total', { kind = 'interactive' })
                platform.wait(math.min(100, attempt * 10))
            else
                logger:error('interactive database transaction failed', { durationMs = duration, error = failureDetails(failure), attempt = attempt })
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
        local rows, err = database:query([[SELECT `resource_name`, COUNT(*) AS `total_count`,
                SUM(CASE WHEN `state` = 'applied' THEN 1 ELSE 0 END) AS `applied_count`,
                SUM(CASE WHEN `state` = 'applying' THEN 1 ELSE 0 END) AS `applying_count`,
                SUM(CASE WHEN `state` = 'failed' THEN 1 ELSE 0 END) AS `failed_count`,
                SUM(`attempts`) AS `attempt_count`
            FROM `synex_schema_migration_attempts`
            GROUP BY `resource_name` ORDER BY `resource_name` LIMIT ?]], { maximumResources + 1 })
        if err then return nil, err end
        rows = rows or {}
        local resources = {}
        local totals = { defined = 0, applied = 0, applying = 0, failed = 0, attempts = 0 }
        for index = 1, math.min(#rows, maximumResources) do
            local row = rows[index]
            local entry = {
                resource = row.resource_name,
                defined = tonumber(row.total_count) or 0,
                applied = tonumber(row.applied_count) or 0,
                applying = tonumber(row.applying_count) or 0,
                failed = tonumber(row.failed_count) or 0,
                attempts = tonumber(row.attempt_count) or 0
            }
            resources[index] = entry
            for key in pairs(totals) do totals[key] = totals[key] + entry[key] end
        end
        return { resources = resources, totals = totals, truncated = #rows > maximumResources }, nil
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

    local function recordMigrationFailure(resourceName, migrationId, errorCode)
        local _, markerError = database:update([[UPDATE `synex_schema_migration_attempts`
            SET `state` = 'failed', `last_error_code` = ?, `finished_at` = CURRENT_TIMESTAMP(6)
            WHERE `resource_name` = ? AND `migration_id` = ?]],
            { errorCode, resourceName, migrationId })
        if markerError then
            logger:error('migration failure marker write failed', {
                resource = resourceName,
                migration = migrationId,
                primaryCode = errorCode,
                code = markerError.code
            })
            return nil, markerError
        end
        return true, nil
    end

    function migrationManager:apply(resourceName, migrations)
        for _, migration in ipairs(migrations or {}) do
            local contents = platform.loadResourceFile(resourceName, migration.path)
            if not contents then
                return nil, foundation.error('MIGRATION_NOT_FOUND', ('Migration %s is missing.'):format(migration.path))
            end
            local checksum = sha256(contents:gsub('\r\n', '\n'))
            local rows, readErr = database:query([[SELECT `checksum_sha256` FROM `synex_schema_migrations`
                WHERE `resource_name` = ? AND `migration_id` = ?]], { resourceName, migration.id })
            if readErr then return nil, readErr end
            if rows and rows[1] then
                if rows[1].checksum_sha256 ~= checksum then
                    return nil, foundation.error('MIGRATION_CHECKSUM_MISMATCH',
                        ('Applied migration %s/%s was modified.'):format(resourceName, migration.id))
                end
                local attemptRows, attemptReadError = database:query([[SELECT `checksum_sha256` FROM `synex_schema_migration_attempts`
                    WHERE `resource_name` = ? AND `migration_id` = ? LIMIT 1]], { resourceName, migration.id })
                if attemptReadError then return nil, attemptReadError end
                if attemptRows and attemptRows[1] and attemptRows[1].checksum_sha256 ~= checksum then
                    return nil, foundation.error('MIGRATION_CHECKSUM_MISMATCH',
                        ('Migration attempt history for %s/%s has a different checksum.'):format(resourceName, migration.id))
                end
                local _, attemptRepairError = database:update([[INSERT INTO `synex_schema_migration_attempts`
                    (`resource_name`, `migration_id`, `checksum_sha256`, `state`, `attempts`, `last_error_code`, `started_at`, `finished_at`)
                    VALUES (?, ?, ?, 'applied', 1, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))
                    ON DUPLICATE KEY UPDATE `state` = 'applied', `last_error_code` = NULL,
                        `finished_at` = CURRENT_TIMESTAMP(6)]], { resourceName, migration.id, checksum })
                if attemptRepairError then return nil, attemptRepairError end
            else
                local attempts, attemptsError = database:query([[SELECT `checksum_sha256`, `state`, `attempts`
                    FROM `synex_schema_migration_attempts`
                    WHERE `resource_name` = ? AND `migration_id` = ? LIMIT 1]], { resourceName, migration.id })
                if attemptsError then return nil, attemptsError end
                if attempts and attempts[1] and attempts[1].checksum_sha256 ~= checksum then
                    return nil, foundation.error('MIGRATION_CHECKSUM_MISMATCH',
                        ('Incomplete migration %s/%s was modified before retry.'):format(resourceName, migration.id))
                end
                local _, attemptWriteError = database:update([[INSERT INTO `synex_schema_migration_attempts`
                    (`resource_name`, `migration_id`, `checksum_sha256`, `state`, `attempts`, `last_error_code`, `started_at`, `finished_at`)
                    VALUES (?, ?, ?, 'applying', 1, NULL, CURRENT_TIMESTAMP(6), NULL)
                    ON DUPLICATE KEY UPDATE `state` = 'applying', `attempts` = LEAST(`attempts` + 1, 65535),
                        `last_error_code` = NULL, `started_at` = CURRENT_TIMESTAMP(6), `finished_at` = NULL]],
                    { resourceName, migration.id, checksum })
                if attemptWriteError then return nil, attemptWriteError end
                local started = foundation.monotonicMs()
                for _, statement in ipairs(splitStatements(contents)) do
                    local renewed, renewErr = self:renewLease()
                    if not renewed then
                        recordMigrationFailure(resourceName, migration.id, renewErr.code or 'LEASE_LOST')
                        return nil, renewErr
                    end
                    local _, statementErr = database:update(statement, {})
                    if statementErr then
                        recordMigrationFailure(resourceName, migration.id, statementErr.code or 'DATABASE_ERROR')
                        return nil, statementErr
                    end
                end
                local _, insertErr = database:insert([[INSERT INTO `synex_schema_migrations`
                    (`migration_id`, `resource_name`, `checksum_sha256`, `duration_ms`, `instance_id`)
                    VALUES (?, ?, ?, ?, ?)]], {
                    migration.id, resourceName, checksum,
                    math.max(0, foundation.monotonicMs() - started), leaseOwner
                })
                if insertErr then
                    recordMigrationFailure(resourceName, migration.id, insertErr.code or 'DATABASE_ERROR')
                    return nil, insertErr
                end
                local completedAffected, completedError = database:update([[UPDATE `synex_schema_migration_attempts`
                    SET `state` = 'applied', `last_error_code` = NULL, `finished_at` = CURRENT_TIMESTAMP(6)
                    WHERE `resource_name` = ? AND `migration_id` = ? AND `checksum_sha256` = ?]],
                    { resourceName, migration.id, checksum })
                if completedError then return nil, completedError end
                if tonumber(completedAffected) ~= 1 then
                    return nil, foundation.error('MIGRATION_ATTEMPT_STATE_LOST',
                        ('Migration attempt state for %s/%s changed unexpectedly.'):format(resourceName, migration.id))
                end
                logger:info('migration applied', { resource = resourceName, migration = migration.id, checksum = checksum })
            end
        end
        return true, nil
    end

    local leases = {}
    function leases:acquire(name, owner, ttlSeconds, requesterInstanceId, requesterBootId)
        if type(name) ~= 'string' or #name < 1 or #name > 96 or type(owner) ~= 'string' or #owner < 1 or #owner > 96 then
            return nil, foundation.error('INVALID_LEASE', 'Lease name or owner is invalid.')
        end
        local requesterFenced = requesterInstanceId ~= nil or requesterBootId ~= nil
        local sessionLease = name:sub(1, 8) == 'session:'
        if sessionLease and not requesterFenced then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Session leases require the current runtime boot authority.')
        end
        if requesterFenced and (type(requesterInstanceId) ~= 'string' or #requesterInstanceId < 1
            or #requesterInstanceId > 36
            or owner:sub(1, #requesterInstanceId + 1) ~= requesterInstanceId .. ':'
            or type(requesterBootId) ~= 'string' or #requesterBootId < 1 or #requesterBootId > 36
            or (type(runtimeInstanceId) == 'string' and requesterInstanceId ~= runtimeInstanceId)) then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Session lease requester authority is invalid.')
        end
        ttlSeconds = math.max(5, math.min(tonumber(ttlSeconds) or 30, 300))
        if requesterFenced then
            local acquiredFence = nil
            local authorityError = nil
            local committed, transactionError = database:withTransaction(function(query)
                local requester = query([[SELECT `status` FROM `synex_instances`
                    WHERE `instance_id` = ? AND `status` = 'ready' FOR UPDATE]],
                    { requesterInstanceId }) or {}
                if not requester[1] then
                    authorityError = foundation.error('LEASE_BUSY',
                        'The requester no longer owns ready runtime authority.', { retryable = true })
                    return false
                end
                local boot = query([[SELECT `boot_id` FROM `synex_instance_boots`
                    WHERE `instance_id` = ? AND `boot_id` = ? FOR UPDATE]],
                    { requesterInstanceId, requesterBootId }) or {}
                if not boot[1] then
                    authorityError = foundation.error('LEASE_BUSY',
                        'The requester boot generation is no longer current.', { retryable = true })
                    return false
                end
                query([[INSERT INTO `synex_cluster_leases`
                    (`lease_name`, `owner_id`, `fencing_token`, `expires_at`)
                    VALUES (?, ?, 1, TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))
                    ON DUPLICATE KEY UPDATE
                        `owner_id` = IF(`expires_at` <= CURRENT_TIMESTAMP(6) OR `owner_id` = ?,
                            ?, `owner_id`),
                        `fencing_token` = IF(`expires_at` <= CURRENT_TIMESTAMP(6) OR `owner_id` = ?,
                            `fencing_token` + 1, `fencing_token`),
                        `expires_at` = IF(`expires_at` <= CURRENT_TIMESTAMP(6) OR `owner_id` = ?,
                            TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)), `expires_at`)]],
                    { name, owner, ttlSeconds, owner, owner, owner, owner, ttlSeconds })
                local rows = query([[SELECT `owner_id`, `fencing_token`,
                        (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
                    FROM `synex_cluster_leases` WHERE `lease_name` = ? FOR UPDATE]], { name }) or {}
                local row = rows[1]
                if not row or row.owner_id ~= owner or tonumber(row.valid) ~= 1
                    or not tonumber(row.fencing_token) then
                    authorityError = foundation.error('LEASE_BUSY',
                        'The lease is held by another server instance.', { retryable = true })
                    return false
                end
                acquiredFence = tonumber(row.fencing_token)
                return true
            end)
            if not committed then return nil, authorityError or transactionError end
            return {
                name = name, owner = owner, fencingToken = acquiredFence, ttlSeconds = ttlSeconds,
                requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId
            }, nil
        end
        local _, updateError = database:update([[UPDATE `synex_cluster_leases`
            SET `owner_id` = ?, `fencing_token` = `fencing_token` + 1,
                `expires_at` = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6))
            WHERE `lease_name` = ? AND (`expires_at` < CURRENT_TIMESTAMP(6) OR `owner_id` = ?)]],
            { owner, ttlSeconds, name, owner })
        if updateError then return nil, updateError end
        local _, insertError = database:update([[INSERT IGNORE INTO `synex_cluster_leases`
            (`lease_name`, `owner_id`, `fencing_token`, `expires_at`)
            VALUES (?, ?, 1, TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]],
            { name, owner, ttlSeconds })
        if insertError then return nil, insertError end
        local rows, readError = database:query([[SELECT `owner_id`, `fencing_token`,
                (`expires_at` > CURRENT_TIMESTAMP(6)) AS `valid`
            FROM `synex_cluster_leases` WHERE `lease_name` = ? LIMIT 1]], { name })
        if readError then return nil, readError end
        local row = rows and rows[1]
        if not row or row.owner_id ~= owner or tonumber(row.valid) ~= 1 then
            return nil, foundation.error('LEASE_BUSY', 'The lease is held by another server instance.', { retryable = true })
        end
        return { name = name, owner = owner, fencingToken = tonumber(row.fencing_token),
            ttlSeconds = ttlSeconds }, nil
    end
    function leases:renew(lease)
        if type(lease) ~= 'table' then return nil, foundation.error('INVALID_LEASE', 'Lease snapshot is invalid.') end
        local requesterFenced = lease.requesterInstanceId ~= nil or lease.requesterBootId ~= nil
        local leaseName = lease.name or lease.leaseName
        if type(leaseName) == 'string' and leaseName:sub(1, 8) == 'session:' and not requesterFenced then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Session lease renewal requires the current runtime boot authority.')
        end
        if requesterFenced and (type(lease.requesterInstanceId) ~= 'string'
            or #lease.requesterInstanceId < 1 or #lease.requesterInstanceId > 36
            or type(lease.requesterBootId) ~= 'string'
            or #lease.requesterBootId < 1 or #lease.requesterBootId > 36) then
            return nil, foundation.error('INVALID_LEASE_AUTHORITY',
                'Session lease renewal authority is invalid.')
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
        local _, err = database:update([[UPDATE `synex_cluster_leases` SET `expires_at` = CURRENT_TIMESTAMP(6)
            WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?]],
            { lease.name, lease.owner, lease.fencingToken })
        return err and nil or true, err
    end

    return {
        database = database,
        migrations = migrationManager,
        leases = leases,
        sha256 = sha256,
        splitStatements = splitStatements
    }
end
