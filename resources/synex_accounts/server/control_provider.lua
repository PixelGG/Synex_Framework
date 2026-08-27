return function(Foundation)
    local OPERATIONS = {
        'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings'
    }
    local VIEWS = {
        { id = 'overview', label = 'Accounts overview', operation = 'summary', presentation = 'key-value', order = 10,
            description = 'Compact financial-domain totals.' },
        { id = 'health', label = 'Accounts health', operation = 'health', presentation = 'key-value', order = 20,
            description = 'Read-only ledger and account consistency checks.' },
        { id = 'currencies', label = 'Currencies', operation = 'list', presentation = 'table', order = 30,
            description = 'Bounded currency and topology read models.' },
        { id = 'accounts', label = 'Accounts', operation = 'list', presentation = 'table', order = 40,
            description = 'Cursor-based account read model.' },
        { id = 'ledger', label = 'Ledger', operation = 'metrics', presentation = 'metrics', order = 50,
            description = 'Measured double-entry ledger totals.' },
        { id = 'transactions', label = 'Transactions', operation = 'list', presentation = 'table', order = 60,
            description = 'Cursor-based posted transaction metadata.' },
        { id = 'holds', label = 'Holds', operation = 'list', presentation = 'table', order = 70,
            description = 'Cursor-based hold lifecycle state.' },
        { id = 'access', label = 'Access', operation = 'list', presentation = 'table', order = 80,
            description = 'Bounded access-role and grant aggregates.' },
        { id = 'integrity', label = 'Integrity', operation = 'list', presentation = 'findings', order = 90,
            description = 'Currency integrity read models.' },
        { id = 'reconciliation', label = 'Reconciliation', operation = 'list', presentation = 'table', order = 100,
            description = 'Bounded completed reconciliation runs.' },
        { id = 'anomalies', label = 'Anomalies', operation = 'findings', presentation = 'findings', order = 110,
            description = 'Cursor-based reconciliation findings.' },
        { id = 'economy', label = 'Economy', operation = 'metrics', presentation = 'metrics', order = 120,
            description = 'Measured 24-hour, 7-day, and 30-day economy windows.' },
        { id = 'outbox', label = 'Outbox', operation = 'list', presentation = 'table', order = 130,
            description = 'Bounded delivery metadata without event payloads.' },
        { id = 'account', label = 'Account inspector', operation = 'inspect', presentation = 'detail', order = 140,
            description = 'Inspect one account and its bounded activity.', input = { fields = {
                { key = 'id', label = 'Account ID', source = 'id', type = 'string', format = 'uuid', required = true, minLength = 36, maxLength = 36 },
            } } },
        { id = 'transaction', label = 'Transaction inspector', operation = 'inspect', presentation = 'detail', order = 150,
            description = 'Inspect one transaction and its bounded entries.', input = { fields = {
                { key = 'id', label = 'Transaction ID', source = 'id', type = 'string', format = 'uuid', required = true, minLength = 36, maxLength = 36 },
            } } },
        { id = 'hold', label = 'Hold inspector', operation = 'inspect', presentation = 'detail', order = 160,
            description = 'Inspect one hold without mutating it.', input = { fields = {
                { key = 'id', label = 'Hold ID', source = 'id', type = 'string', format = 'uuid', required = true, minLength = 36, maxLength = 36 },
            } } },
        { id = 'outbox_detail', label = 'Outbox inspector', operation = 'inspect', presentation = 'detail', order = 170,
            description = 'Inspect delivery metadata without exposing its payload.', input = { fields = {
                { key = 'id', label = 'Outbox ID', source = 'id', type = 'string', format = 'uuid', required = true, minLength = 36, maxLength = 36 },
            } } },
        { id = 'search', label = 'Search', operation = 'search', presentation = 'table', order = 180,
            description = 'Exact lookup by account or transaction identifier.' },
        { id = 'character_relations', label = 'Character relations', operation = 'inspect', presentation = 'detail', order = 190,
            description = 'Bounded account links for one exact character identifier without balances.' },
    }

    for _, view in ipairs(VIEWS) do
        view.accessClass = 'financial'
        if view.id == 'search' then
            view.search = { kinds = {
                { id = 'account', modes = { 'exact' }, accessClass = 'financial' },
                { id = 'transaction', modes = { 'exact' }, accessClass = 'financial' },
            } }
        end
    end

    local function failure(code, message, retryable)
        return Foundation.domainError(code, message, retryable == true)
    end

    local function validateRequest(request, allowed, required)
        local copied, candidate = pcall(Foundation.copyPlain, request, {
            maximumDepth = 3, maximumKeys = 12, maximumStringBytes = 256,
        })
        if not copied then
            return nil, failure('VALIDATION_FAILED', 'The Accounts control request is invalid.')
        end
        local allowedMap = {}
        for _, key in ipairs(allowed) do allowedMap[key] = true end
        local valid, validationError = Foundation.validateShape(
            candidate, allowedMap, required or {})
        if not valid then return nil, validationError end
        return candidate, nil
    end

    local function validLimit(value)
        return value == nil or type(value) == 'number'
            and math.type(value) == 'integer' and value >= 1 and value <= 25
    end

    local function validCursor(value)
        return value == nil or Foundation.isPublicId(value)
    end

    local function validCurrencyCursor(value)
        return value == nil or type(value) == 'string' and #value >= 2 and #value <= 16
            and value:match('^[a-z][a-z0-9_]*$') ~= nil
    end

    local function exactKeys(candidate, keys)
        local allowed = {}
        for _, key in ipairs(keys) do allowed[key] = true end
        for key in pairs(candidate) do if not allowed[key] then return false end end
        return true
    end

    local function emptyObject(value)
        return value == nil or type(value) == 'table' and next(value) == nil
    end

    local function nested(value, allowed, required)
        return validateRequest(value or {}, allowed, required or {})
    end

    return function(options)
        local database = assert(options.database, 'Accounts control provider database is required')
        local operatorMethods = assert(options.operatorMethods,
            'Accounts control provider operator methods are required')
        local query = assert(options.query, 'Accounts control provider query function is required')
        local errorSink = assert(options.errorSink, 'Accounts control provider error sink is required')
        local getApi = assert(options.getApi, 'Accounts control provider API getter is required')

        local function runQuery(sql, parameters, context)
            local called, rows = pcall(query, sql, parameters or {})
            if called and type(rows) == 'table' then return rows, nil end
            pcall(errorSink, {
                operation = 'control_query', code = 'DATABASE_ERROR',
                traceId = type(context) == 'table' and context.traceId or 'unavailable',
            })
            return nil, failure('DATABASE_ERROR', 'The Accounts control read failed.', true)
        end

        local function controlSummary(context)
            local called, value, summaryError = pcall(
                database.getAccountsControlSummary, database)
            if called and value then return value, summaryError end
            pcall(errorSink, { operation = 'control_summary', code = 'DATABASE_ERROR',
                traceId = type(context) == 'table' and context.traceId or 'unavailable' })
            return nil, type(summaryError) == 'table' and summaryError
                or failure('DATABASE_ERROR', 'The Accounts control summary is unavailable.', true)
        end

        local function domainContext(context)
            local api = getApi()
            if type(api) ~= 'table' or type(api.ownerEpoch) ~= 'number'
                or math.type(api.ownerEpoch) ~= 'integer' or api.ownerEpoch < 1 then
                return nil, failure('UNAVAILABLE', 'The Accounts Core owner epoch is unavailable.', true)
            end
            return {
                caller = 'synex_accounts', callerEpoch = api.ownerEpoch,
                traceId = type(context) == 'table' and context.traceId or 'control_unavailable',
            }, nil
        end

        local function invokeOperator(methodName, request, context)
            local handler = operatorMethods[methodName]
            if not Foundation.isCallable(handler) then
                return nil, failure('UNAVAILABLE', 'The Accounts inspector is unavailable.', true)
            end
            local internalContext, contextError = domainContext(context)
            if not internalContext then return nil, contextError end
            local called, value, operationError = pcall(handler, request, internalContext)
            if called then return value, operationError end
            pcall(errorSink, {
                operation = 'control_' .. methodName, code = 'DATABASE_ERROR',
                traceId = internalContext.traceId,
            })
            return nil, failure('DATABASE_ERROR', 'The Accounts inspector failed.', true)
        end

        local function page(rows, limit, cursorField)
            local truncated = #rows > limit
            if truncated then rows[#rows] = nil end
            return {
                items = rows,
                nextCursor = truncated and rows[#rows] and rows[#rows][cursorField] or nil,
                hasMore = truncated, truncated = truncated,
            }
        end

        local function appendFilter(clauses, parameters, condition, value)
            if value == nil then return end
            clauses[#clauses + 1] = condition
            parameters[#parameters + 1] = value
        end

        local function finishQuery(prefix, clauses, orderBy, parameters, limit)
            local statement = prefix
            if #clauses > 0 then statement = statement .. ' WHERE ' .. table.concat(clauses, ' AND ') end
            parameters[#parameters + 1] = limit + 1
            return statement .. ' ORDER BY ' .. orderBy .. ' LIMIT ?', parameters
        end

        local function inspectCharacterRelations(characterId, limit, context)
            local rows, readError = runQuery([[SELECT
                    `account`.`public_id` AS `accountId`,
                    `account`.`account_role` AS `accountRole`,
                    `account`.`status`,
                    `currency`.`currency_code` AS `currencyCode`,
                    CAST(COUNT(*) OVER() AS CHAR) AS `relationCount`
                FROM `synex_account_owners` AS `owner`
                INNER JOIN `synex_accounts` AS `account`
                    ON `account`.`id` = `owner`.`account_id`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `account`.`currency_id`
                WHERE `owner`.`owner_kind` = 'character' AND `owner`.`owner_ref` = ?
                ORDER BY `account`.`public_id` ASC
                LIMIT ?]], { characterId, limit }, context)
            if not rows then return nil, readError end
            local total = rows[1] and tonumber(rows[1].relationCount) or 0
            local items = {}
            for index, row in ipairs(rows) do
                items[index] = {
                    accountId = row.accountId,
                    accountRole = row.accountRole,
                    status = row.status,
                    currencyCode = row.currencyCode,
                }
            end
            local truncated = total > #items
            return {
                view = 'character_relations',
                characterId = characterId,
                count = total,
                items = items,
                limit = limit,
                hasMore = truncated,
                truncated = truncated,
                balancesExposed = false,
                payloadsExposed = false,
            }, nil
        end

        local function listAccounts(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters, '`account`.`public_id` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`account`.`status` = ?', candidate.status)
            local sql = [[SELECT `account`.`public_id` AS `account_id`,
                    `account`.`account_key`, `account`.`account_role`, `account`.`status`,
                    `owner`.`owner_kind`, `owner`.`owner_ref`, `currency`.`currency_code`,
                    CAST(`account`.`version` AS CHAR) AS `version`,
                    DATE_FORMAT(`account`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`
                FROM `synex_accounts` AS `account`
                INNER JOIN `synex_account_owners` AS `owner`
                    ON `owner`.`account_id` = `account`.`id`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `account`.`currency_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`account`.`public_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'account_id'), nil
        end

        local function listTransactions(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters,
                '`transaction`.`public_id` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`transaction`.`status` = ?', candidate.status)
            local sql = [[SELECT
                    `transaction`.`public_id` AS `transaction_id`,
                    `currency`.`currency_code`, `transaction`.`transaction_kind`,
                    `transaction`.`posting_model`, `transaction`.`status`,
                    `transaction`.`reason_code`, `transaction`.`source_resource`,
                    CAST(`transaction`.`entry_count` AS CHAR) AS `entry_count`,
                    DATE_FORMAT(`transaction`.`occurred_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `occurred_at`
                FROM `synex_ledger_transactions` AS `transaction`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `transaction`.`currency_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`transaction`.`public_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'transaction_id'), nil
        end

        local function listHolds(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters, '`hold`.`public_id` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`hold`.`state` = ?', candidate.status)
            local sql = [[SELECT `hold`.`public_id` AS `hold_id`,
                    `source`.`public_id` AS `account_id`,
                    `capture`.`public_id` AS `capture_account_id`, `hold`.`state`,
                    `hold`.`capture_policy`, CAST(`hold`.`amount_minor` AS CHAR) AS `amount_minor`,
                    CAST(`hold`.`remaining_minor` AS CHAR) AS `remaining_minor`,
                    DATE_FORMAT(`hold`.`expires_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `expires_at`
                FROM `synex_account_holds` AS `hold`
                INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `hold`.`account_id`
                INNER JOIN `synex_accounts` AS `capture`
                    ON `capture`.`id` = `hold`.`capture_account_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`hold`.`public_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'hold_id'), nil
        end

        local function listOutbox(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters, '`event_id` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`state` = ?', candidate.status)
            local sql = [[SELECT `event_id`, `event_type`,
                    `aggregate_type`, `aggregate_id`, `state`, CAST(`attempts` AS CHAR) AS `attempts`,
                    `last_error_code`,
                    DATE_FORMAT(`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
                    DATE_FORMAT(`published_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `published_at`
                FROM `synex_account_outbox`]]
            sql, parameters = finishQuery(sql, clauses,
                '`event_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'event_id'), nil
        end

        local function listIntegrity(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters,
                '`currency`.`currency_code` > ?', candidate.cursor)
            local sql = [[SELECT `currency`.`currency_code`,
                    `model`.`status`, CAST(`model`.`model_version` AS CHAR) AS `model_version`,
                    CAST(`model`.`finding_count` AS CHAR) AS `finding_count`,
                    CAST(`model`.`total_entry_sum_minor` AS CHAR) AS `entry_sum_minor`,
                    CAST(`model`.`net_supply_minor` AS CHAR) AS `net_supply_minor`,
                    CAST(`model`.`total_booked_minor` AS CHAR) AS `total_booked_minor`,
                    DATE_FORMAT(`model`.`generated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `generated_at`
                FROM `synex_economy_integrity_read_models` AS `model`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `model`.`currency_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`currency`.`currency_code` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            for _, row in ipairs(rows) do
                local status = type(row.status) == 'string' and row.status:lower() or 'unknown'
                local findingCount = tonumber(row.finding_count) or 0
                local severity = ({
                    critical = 'CRITICAL', error = 'ERROR', failed = 'ERROR',
                    warn = 'WARNING', warning = 'WARNING',
                })[status] or (findingCount > 0 and 'WARNING' or 'INFO')
                row.code = findingCount > 0
                    and 'ACCOUNT_INTEGRITY_FINDINGS' or 'ACCOUNT_INTEGRITY_HEALTHY'
                row.severity = severity
                row.title = 'Ledger integrity - ' .. tostring(row.currency_code)
                row.summary = ('%s finding(s); entry sum %s; net supply %s; booked %s'):format(
                    tostring(row.finding_count), tostring(row.entry_sum_minor),
                    tostring(row.net_supply_minor), tostring(row.total_booked_minor))
            end
            return page(rows, candidate.limit or 20, 'currency_code'), nil
        end

        local function listAnomalies(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters,
                '`finding`.`public_id` > ?', candidate.cursor)
            local sql = [[SELECT `finding`.`public_id` AS `finding_id`,
                    `currency`.`currency_code`, `finding`.`rule_key` AS `rule`,
                    `finding`.`rule_key` AS `code`, `finding`.`rule_key` AS `title`,
                    CASE WHEN `finding`.`severity` = 'warn' THEN 'WARNING'
                        ELSE UPPER(`finding`.`severity`) END AS `severity`,
                    `finding`.`aggregate_type`, `finding`.`aggregate_id`,
                    CONCAT('Currency ', `currency`.`currency_code`,
                        CASE WHEN `finding`.`aggregate_id` IS NULL THEN ''
                            ELSE CONCAT(' · ', `finding`.`aggregate_type`, ':',
                                'finding') END) AS `summary`,
                    DATE_FORMAT(`finding`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
                FROM `synex_economy_anomaly_findings` AS `finding`
                INNER JOIN `synex_economy_reconciliation_runs` AS `run`
                    ON `run`.`id` = `finding`.`run_id`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `run`.`currency_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`finding`.`public_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'finding_id'), nil
        end

        local function listCurrencies(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters,
                '`currency`.`currency_code` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`currency`.`status` = ?', candidate.status)
            local sql = [[SELECT `currency`.`currency_code`, `currency`.`display_name`,
                    `currency`.`minor_unit`, `currency`.`status`,
                    `topology`.`topology_state`, `mint`.`public_id` AS `mint_account_id`,
                    `burn`.`public_id` AS `burn_account_id`,
                    CAST(`topology`.`version` AS CHAR) AS `topology_version`
                FROM `synex_currencies` AS `currency`
                LEFT JOIN `synex_currency_system_topology` AS `topology`
                    ON `topology`.`currency_id` = `currency`.`id`
                LEFT JOIN `synex_accounts` AS `mint` ON `mint`.`id` = `topology`.`mint_account_id`
                LEFT JOIN `synex_accounts` AS `burn` ON `burn`.`id` = `topology`.`burn_account_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`currency`.`currency_code` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'currency_code'), nil
        end

        local function listAccess(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters, '`role`.`public_id` > ?', candidate.cursor)
            local sql = [[SELECT `role`.`public_id` AS `role_id`,
                    `account`.`public_id` AS `account_id`, `role`.`role_key`,
                    `role`.`display_name`, CAST(`role`.`version` AS CHAR) AS `version`,
                    CAST(COUNT(DISTINCT `permission`.`permission_key`) AS CHAR) AS `permissions`,
                    CAST(COUNT(DISTINCT CASE WHEN `grant`.`status` = 'active'
                        THEN `grant`.`id` END) AS CHAR) AS `active_grants`
                FROM `synex_account_access_roles` AS `role`
                INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `role`.`account_id`
                LEFT JOIN `synex_account_access_role_permissions` AS `permission`
                    ON `permission`.`role_id` = `role`.`id`
                LEFT JOIN `synex_account_access_grants` AS `grant`
                    ON `grant`.`role_id` = `role`.`id`]]
            if #clauses > 0 then sql = sql .. ' WHERE ' .. table.concat(clauses, ' AND ') end
            sql = sql .. [[ GROUP BY `role`.`id`, `role`.`public_id`, `account`.`public_id`,
                    `role`.`role_key`, `role`.`display_name`, `role`.`version`
                ORDER BY `role`.`public_id` ASC LIMIT ?]]
            parameters[#parameters + 1] = (candidate.limit or 20) + 1
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'role_id'), nil
        end

        local function listReconciliation(candidate, context)
            local clauses, parameters = {}, {}
            appendFilter(clauses, parameters, '`run`.`public_id` > ?', candidate.cursor)
            appendFilter(clauses, parameters, '`run`.`status` = ?', candidate.status)
            local sql = [[SELECT `run`.`public_id` AS `run_id`,
                    `currency`.`currency_code`, `run`.`status`,
                    CAST(`run`.`model_version` AS CHAR) AS `model_version`,
                    CAST(`run`.`transaction_count` AS CHAR) AS `transactions`,
                    CAST(`run`.`entry_count` AS CHAR) AS `entries`,
                    CAST(`run`.`account_count` AS CHAR) AS `accounts`,
                    CAST(`run`.`finding_count` AS CHAR) AS `findings`,
                    CAST(`run`.`total_entry_sum_minor` AS CHAR) AS `entry_sum_minor`,
                    CAST(`run`.`net_supply_minor` AS CHAR) AS `net_supply_minor`,
                    DATE_FORMAT(`run`.`started_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `started_at`,
                    DATE_FORMAT(`run`.`completed_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `completed_at`
                FROM `synex_economy_reconciliation_runs` AS `run`
                INNER JOIN `synex_currencies` AS `currency`
                    ON `currency`.`id` = `run`.`currency_id`]]
            sql, parameters = finishQuery(sql, clauses,
                '`run`.`public_id` ASC', parameters, candidate.limit or 20)
            local rows, readError = runQuery(sql, parameters, context)
            if not rows then return nil, readError end
            return page(rows, candidate.limit or 20, 'run_id'), nil
        end

        local handlers = {}

        handlers.summary = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'limit' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'overview' or not validLimit(candidate.limit) then
                return nil, failure('VALIDATION_FAILED', 'The Accounts summary view is invalid.')
            end
            local rows, readError = runQuery([[SELECT
                    CAST((SELECT COUNT(*) FROM `synex_currencies`) AS CHAR) AS `currencies`,
                    CAST((SELECT COUNT(*) FROM `synex_accounts`) AS CHAR) AS `accounts`,
                    CAST((SELECT COUNT(*) FROM `synex_ledger_transactions`
                        WHERE `status` = 'posted') AS CHAR) AS `posted_transactions`,
                    CAST((SELECT COUNT(*) FROM `synex_account_holds`
                        WHERE `state` IN ('active', 'partially_captured')) AS CHAR) AS `active_holds`,
                    CAST((SELECT COUNT(*) FROM `synex_account_outbox`
                        WHERE `state` = 'pending') AS CHAR) AS `outbox_pending`,
                    CAST((SELECT COALESCE(SUM(`finding_count`), 0)
                        FROM `synex_economy_integrity_read_models`) AS CHAR) AS `findings`]], {}, context)
            if not rows then return nil, readError end
            local doctor, doctorError = invokeOperator('doctor', {}, context)
            if not doctor then return nil, doctorError end
            local summary = rows[1] or {}
            summary.status = ({
                PASS = 'HEALTHY', WARN = 'WARNING', FAIL = 'ERROR',
            })[doctor.status] or 'UNAVAILABLE'
            summary.doctorStatus = doctor.status
            return summary, nil
        end

        handlers.health = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'limit' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'health' or not validLimit(candidate.limit) then
                return nil, failure('VALIDATION_FAILED', 'The Accounts health view is invalid.')
            end
            local doctor, doctorError = invokeOperator('doctor', {}, context)
            if not doctor then return nil, doctorError end
            doctor.doctorStatus = doctor.status
            doctor.status = ({ PASS = 'HEALTHY', WARN = 'WARNING',
                FAIL = 'ERROR' })[doctor.status] or 'UNAVAILABLE'
            return doctor, nil
        end

        handlers.list = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
            if not candidate then return nil, requestError end
            if not validLimit(candidate.limit) or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED', 'The Accounts list bounds are invalid.')
            end
            local filters, filterError = nested(candidate.filters, { 'status' })
            if not filters then return nil, filterError end
            candidate.status = filters.status
            if candidate.view == 'currencies' then
                local statuses = { active = true, disabled = true }
                if not validCurrencyCursor(candidate.cursor)
                    or candidate.status ~= nil and not statuses[candidate.status] then
                    return nil, failure('VALIDATION_FAILED', 'The currency list is invalid.')
                end
                return listCurrencies(candidate, context)
            end
            if candidate.view == 'access' then
                if not validCursor(candidate.cursor) or candidate.status ~= nil then
                    return nil, failure('VALIDATION_FAILED', 'The access list is invalid.')
                end
                return listAccess(candidate, context)
            end
            if candidate.view == 'reconciliation' then
                local statuses = {
                    running = true, healthy = true, warn = true, error = true,
                    critical = true, failed = true,
                }
                if not validCursor(candidate.cursor)
                    or candidate.status ~= nil and not statuses[candidate.status] then
                    return nil, failure('VALIDATION_FAILED', 'The reconciliation list is invalid.')
                end
                return listReconciliation(candidate, context)
            end
            local accountStatuses = { active = true, frozen = true, closed = true }
            local transactionStatuses = { pending = true, posted = true }
            local holdStatuses = {
                active = true, partially_captured = true, captured = true,
                released = true, expired = true,
            }
            local outboxStatuses = {
                pending = true, publishing = true, published = true, dead = true,
            }
            if candidate.view == 'accounts'
                and validCursor(candidate.cursor)
                and (candidate.status == nil or accountStatuses[candidate.status]) then
                return listAccounts(candidate, context)
            end
            if candidate.view == 'transactions'
                and validCursor(candidate.cursor)
                and (candidate.status == nil or transactionStatuses[candidate.status]) then
                return listTransactions(candidate, context)
            end
            if candidate.view == 'holds'
                and validCursor(candidate.cursor)
                and (candidate.status == nil or holdStatuses[candidate.status]) then
                return listHolds(candidate, context)
            end
            if candidate.view == 'outbox'
                and validCursor(candidate.cursor)
                and (candidate.status == nil or outboxStatuses[candidate.status]) then
                return listOutbox(candidate, context)
            end
            if candidate.view == 'integrity'
                and filters.status == nil
                and validCurrencyCursor(candidate.cursor) then
                return listIntegrity(candidate, context)
            end
            return nil, failure('VALIDATION_FAILED', 'The Accounts list view is invalid.')
        end

        handlers.inspect = function(request, context)
            local candidate, requestError = validateRequest(request, {
                'view', 'id', 'cursor', 'limit', 'filters', 'sort',
            }, { 'view', 'id' })
            if not candidate then return nil, requestError end
            if candidate.view == 'character_relations' then
                if not Foundation.isSubjectId(candidate.id) or candidate.cursor ~= nil
                    or not validLimit(candidate.limit) or (candidate.limit or 8) > 8
                    or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
                    return nil, failure('VALIDATION_FAILED',
                        'The Accounts character relation bounds are invalid.')
                end
                return inspectCharacterRelations(candidate.id, candidate.limit or 8, context)
            end
            if not Foundation.isUuid(candidate.id) or candidate.cursor ~= nil
                or not validLimit(candidate.limit) or not emptyObject(candidate.filters)
                or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED', 'The Accounts inspection bounds are invalid.')
            end
            if candidate.view == 'account'
                then
                return invokeOperator('inspect_account', { account_id = candidate.id }, context)
            end
            if candidate.view == 'transaction'
                then
                return invokeOperator('inspect_transaction', {
                    transaction_id = candidate.id,
                }, context)
            end
            local key, tableName
            if candidate.view == 'hold' then
                key, tableName = candidate.id, 'synex_account_holds'
            elseif candidate.view == 'outbox_detail'
                then
                key, tableName = candidate.id, 'synex_account_outbox'
            else
                return nil, failure('VALIDATION_FAILED', 'The Accounts inspection request is invalid.')
            end
            local sql = tableName == 'synex_account_holds'
                and [[SELECT `public_id` AS `hold_id`, `state`, `capture_policy`,
                        CAST(`amount_minor` AS CHAR) AS `amount_minor`,
                        CAST(`captured_minor` AS CHAR) AS `captured_minor`,
                        CAST(`released_minor` AS CHAR) AS `released_minor`,
                        CAST(`remaining_minor` AS CHAR) AS `remaining_minor`,
                        DATE_FORMAT(`expires_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `expires_at`
                    FROM `synex_account_holds` WHERE `public_id` = ? LIMIT 1]]
                or [[SELECT `event_id`, `event_type`, `aggregate_type`, `aggregate_id`,
                        `state`, CAST(`attempts` AS CHAR) AS `attempts`, `last_error_code`,
                        DATE_FORMAT(`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
                        DATE_FORMAT(`published_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `published_at`
                    FROM `synex_account_outbox` WHERE `event_id` = ? LIMIT 1]]
            local rows, readError = runQuery(sql, { key }, context)
            if not rows then return nil, readError end
            if not rows[1] then
                return nil, failure('NOT_FOUND', 'The Accounts control object does not exist.')
            end
            return rows[1], nil
        end

        handlers.search = function(request, context)
            local candidate, requestError = validateRequest(request,
                { 'query', 'cursor', 'limit', 'filters', 'sort' }, { 'query' })
            if not candidate then return nil, requestError end
            local query, queryError = nested(candidate.query,
                { 'kind', 'value', 'mode' }, { 'kind', 'value', 'mode' })
            if not query then return nil, queryError end
            if query.mode ~= 'exact' or not Foundation.isUuid(query.value)
                or candidate.cursor ~= nil or not validLimit(candidate.limit)
                or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED',
                    'Accounts search supports exact public UUIDs only; prefix mode is unsupported.')
            end
            local value, searchError
            if query.kind == 'account' then
                value, searchError = invokeOperator('inspect_account', { account_id = query.value }, context)
            elseif query.kind == 'transaction' then
                value, searchError = invokeOperator('inspect_transaction', {
                    transaction_id = query.value,
                }, context)
            else
                return nil, failure('VALIDATION_FAILED', 'The Accounts search kind is invalid.')
            end
            if not value then return nil, searchError end
            return { items = {{ kind = query.kind, id = query.value, result = value }},
                hasMore = false, truncated = false }, nil
        end

        handlers.metrics = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'limit', 'filters' }, { 'view' })
            if not candidate then return nil, requestError end
            local filters, filterError = nested(candidate.filters, { 'period' })
            if not filters then return nil, filterError end
            local allowedPeriods = { ['24h'] = true, ['7d'] = true, ['30d'] = true }
            if candidate.view ~= 'economy' and candidate.view ~= 'ledger'
                or not validLimit(candidate.limit)
                or filters.period ~= nil and not allowedPeriods[filters.period] then
                return nil, failure('VALIDATION_FAILED', 'The Accounts metrics view is invalid.')
            end
            if candidate.view == 'ledger' then
                if filters.period ~= nil then
                    return nil, failure('VALIDATION_FAILED',
                        'Ledger totals do not accept an economy period filter.')
                end
                local summary, summaryError = controlSummary(context)
                if not summary then return nil, summaryError end
                return summary.ledger, nil
            end
            local summary, summaryError = controlSummary(context)
            if not summary then return nil, summaryError end
            if filters.period ~= nil then
                for _, period in ipairs(summary.economy and summary.economy.periods or {}) do
                    if period.period == filters.period then return period, nil end
                end
                return nil, failure('UNAVAILABLE',
                    'The requested measured economy period is unavailable.', true)
            end
            local called, operational, metricsError = pcall(
                database.getOperationalMetrics, database)
            if not called or not operational then
                return nil, type(metricsError) == 'table' and metricsError
                    or failure('DATABASE_ERROR', 'Accounts metrics are unavailable.', true)
            end
            return { periods = summary.economy and summary.economy.periods or {},
                operational = operational }, nil
        end

        handlers.findings = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'anomalies' or not validLimit(candidate.limit)
                or not validCursor(candidate.cursor) or not emptyObject(candidate.filters)
                or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED', 'The Accounts findings request is invalid.')
            end
            return listAnomalies(candidate, context)
        end

        local boundaryHandlers = {}
        for operation, handler in pairs(handlers) do
            boundaryHandlers[operation] = function(...)
                local value, operationError = handler(...)
                if value == nil and operationError ~= nil then return false, operationError end
                return value, operationError
            end
        end

        local provider = {}
        function provider:register(api)
            local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
                and api.ControlProviders.register or nil
            if not Foundation.isCallable(register) then
                return nil, failure('UNAVAILABLE', 'The Core control-provider registry is unavailable.', true)
            end
            local called, metadata, registrationError = pcall(register, {
                schemaVersion = 1, namespace = 'accounts', label = 'Accounts',
                category = 'domain', version = '1.0.0', operations = boundaryHandlers,
                views = VIEWS,
            })
            if called and metadata then return metadata, nil end
            return nil, type(registrationError) == 'table' and registrationError
                or failure('UNAVAILABLE', 'The Accounts control provider could not be registered.', true)
        end
        provider.operations, provider.views = OPERATIONS, VIEWS
        return provider
    end
end
