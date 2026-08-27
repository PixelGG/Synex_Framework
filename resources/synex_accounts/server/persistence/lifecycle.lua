return function(port, context)
local Foundation = assert(context.foundation, 'accounts lifecycle requires Foundation')
local domainError = assert(context.domainError, 'accounts lifecycle requires domainError')
local jsonEncode = assert(context.jsonEncode, 'accounts lifecycle requires jsonEncode')
local jsonDecode = assert(context.jsonDecode, 'accounts lifecycle requires jsonDecode')
local random = assert(context.random, 'accounts lifecycle requires random')
local uuidV4 = assert(context.uuidV4, 'accounts lifecycle requires uuidV4')
local one = assert(context.one, 'accounts lifecycle requires one')
local many = assert(context.many, 'accounts lifecycle requires many')
local withRetriableTransaction = assert(context.withRetriableTransaction,
    'accounts lifecycle requires retriable transactions')

local RESOURCE = 'synex_accounts'
local RESOURCE_PRINCIPAL = 'synex_accounts'
local ACTIVE_HOLD_STATES = "('active', 'partially_captured')"
local MAX_DURABLE_JSON_BYTES = 32768

local function txRows(query, sql, parameters)
    local rows = query(sql, parameters or {})
    if type(rows) ~= 'table' then
        error('accounts lifecycle transaction returned an invalid result', 0)
    end
    return rows
end

local function affectedRows(value)
    local parsed = type(value) == 'table' and tonumber(value.affectedRows) or tonumber(value)
    if not parsed or math.type(parsed) ~= 'integer' or parsed < 0
        or parsed > Foundation.MAX_MINOR then return nil end
    return parsed
end

local function validTraceId(value)
    return value == nil or type(value) == 'string' and #value >= 8 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
end

local function decimalIsZero(value)
    return type(value) == 'string' and value:match('^%-?0+$') ~= nil
end

local function lifecycleState(query, ownerKind, ownerRef, lockRows)
    local lockSuffix = lockRows and ' FOR UPDATE' or ''
    local accounts = txRows(query, [[SELECT `account`.`id`, `account`.`public_id`,
            `account`.`status`, `account`.`version`,
            CAST(`snapshot`.`booked_minor` AS CHAR) AS `booked_minor`,
            CAST(COALESCE((SELECT SUM(`entry`.`amount_minor`)
                FROM `synex_ledger_entries` AS `entry`
                WHERE `entry`.`account_id` = `account`.`id`), 0) AS CHAR)
                AS `ledger_minor`
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_owners` AS `owner`
            ON `owner`.`account_id` = `account`.`id`
        LEFT JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ?
        ORDER BY `account`.`id` ASC]] .. lockSuffix, { ownerKind, ownerRef })

    local nonzeroAccounts = 0
    local openAccounts = 0
    for _, account in ipairs(accounts) do
        local accountId = tonumber(account.id)
        local version = tonumber(account.version)
        local bookedMinor = tostring(account.booked_minor)
        local ledgerMinor = tostring(account.ledger_minor)
        if not accountId or math.type(accountId) ~= 'integer' or accountId < 1
            or not version or math.type(version) ~= 'integer' or version < 1
            or not Foundation.isUuid(account.public_id)
            or (account.status ~= 'active' and account.status ~= 'frozen'
                and account.status ~= 'closed')
            or bookedMinor:match('^%-?%d+$') == nil
            or ledgerMinor:match('^%-?%d+$') == nil then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'An account lifecycle state is invalid.')
        end
        if bookedMinor ~= ledgerMinor then
            return nil, domainError('INTEGRITY_VIOLATION',
                'An account snapshot differs from its immutable ledger balance.')
        end
        if not decimalIsZero(bookedMinor) then
            nonzeroAccounts = nonzeroAccounts + 1
        end
        if account.status ~= 'closed' then openAccounts = openAccounts + 1 end
    end

    local total = txRows(query, [[SELECT CAST(COALESCE(SUM(`snapshot`.`booked_minor`), 0) AS CHAR)
            AS `booked_minor_total`
        FROM `synex_accounts` AS `account`
        INNER JOIN `synex_account_owners` AS `owner`
            ON `owner`.`account_id` = `account`.`id`
        LEFT JOIN `synex_account_balance_snapshots` AS `snapshot`
            ON `snapshot`.`account_id` = `account`.`id`
            AND `snapshot`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_balance_snapshots` AS `latest`
                WHERE `latest`.`account_id` = `account`.`id`)
        WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ?]],
        { ownerKind, ownerRef })[1]
    local bookedMinorTotal = total and tostring(total.booked_minor_total) or nil
    if not bookedMinorTotal or bookedMinorTotal:match('^%-?%d+$') == nil then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The account lifecycle aggregate balance is invalid.')
    end

    local holds = txRows(query, ([[SELECT `hold`.`id`
        FROM `synex_account_holds` AS `hold`
        LEFT JOIN `synex_account_owners` AS `source_owner`
            ON `source_owner`.`account_id` = `hold`.`account_id`
        LEFT JOIN `synex_account_owners` AS `capture_owner`
            ON `capture_owner`.`account_id` = `hold`.`capture_account_id`
        WHERE `hold`.`state` IN %s AND `hold`.`remaining_minor` > 0
            AND `hold`.`expires_at` > CURRENT_TIMESTAMP(6)
            AND ((`source_owner`.`owner_kind` = ? AND `source_owner`.`owner_ref` = ?)
                OR (`capture_owner`.`owner_kind` = ? AND `capture_owner`.`owner_ref` = ?))
        ORDER BY `hold`.`id` ASC%s]]):format(ACTIVE_HOLD_STATES, lockSuffix),
        { ownerKind, ownerRef, ownerKind, ownerRef })

    local grants = txRows(query, [[SELECT `grant`.`id`
        FROM `synex_account_access_grants` AS `grant`
        LEFT JOIN `synex_account_owners` AS `grant_owner`
            ON `grant_owner`.`account_id` = `grant`.`account_id`
        WHERE `grant`.`status` = 'active' AND (
            (`grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?)
            OR (`grant_owner`.`owner_kind` = ? AND `grant_owner`.`owner_ref` = ?))
        ORDER BY `grant`.`id` ASC]] .. lockSuffix,
        { ownerKind, ownerRef, ownerKind, ownerRef })

    return {
        accounts = #accounts,
        openAccounts = openAccounts,
        nonzeroAccounts = nonzeroAccounts,
        nonterminalHolds = #holds,
        activeGrants = #grants,
        bookedMinorTotal = bookedMinorTotal,
    }, nil
end

local function anonymizeReferences(query, ownerKind, ownerRef, anonymousRef)
    local invalidEvidence = txRows(query, [[SELECT CAST(
            (SELECT COUNT(*) FROM `synex_account_operations`
                WHERE `response_json` IS NOT NULL
                    AND LOCATE(JSON_QUOTE(?), `response_json`) > 0
                    AND (JSON_VALID(`response_json`) <> 1
                        OR OCTET_LENGTH(`response_json`) > ?
                        OR OCTET_LENGTH(REPLACE(`response_json`,
                            JSON_QUOTE(?), JSON_QUOTE(?))) > ?))
            + (SELECT COUNT(*) FROM `synex_account_audit`
                WHERE LOCATE(JSON_QUOTE(?), `snapshot_json`) > 0
                    AND (JSON_VALID(`snapshot_json`) <> 1
                        OR OCTET_LENGTH(`snapshot_json`) > ?
                        OR OCTET_LENGTH(REPLACE(`snapshot_json`,
                            JSON_QUOTE(?), JSON_QUOTE(?))) > ?))
            + (SELECT COUNT(*) FROM `synex_account_outbox`
                WHERE LOCATE(JSON_QUOTE(?), `payload_json`) > 0
                    AND (JSON_VALID(`payload_json`) <> 1
                        OR OCTET_LENGTH(`payload_json`) > ?
                        OR OCTET_LENGTH(REPLACE(`payload_json`,
                            JSON_QUOTE(?), JSON_QUOTE(?))) > ?))
        AS CHAR) AS `invalid_count`]], {
        ownerRef, MAX_DURABLE_JSON_BYTES,
        ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES,
        ownerRef, MAX_DURABLE_JSON_BYTES,
        ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES,
        ownerRef, MAX_DURABLE_JSON_BYTES,
        ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES,
    })[1]
    local invalidCount = invalidEvidence and tonumber(invalidEvidence.invalid_count) or nil
    if not invalidCount or math.type(invalidCount) ~= 'integer' or invalidCount < 0 then
        error('accounts lifecycle durable JSON evidence check returned an invalid result', 0)
    end
    if invalidCount > 0 then
        error('accounts lifecycle durable JSON evidence exceeds its safe rewrite bound', 0)
    end

    txRows(query, [[UPDATE `synex_account_operations`
        SET `response_json` = REPLACE(
            `response_json`, JSON_QUOTE(?), JSON_QUOTE(?))
        WHERE `response_json` IS NOT NULL
            AND JSON_VALID(`response_json`) = 1
            AND OCTET_LENGTH(`response_json`) <= ?
            AND LOCATE(JSON_QUOTE(?), `response_json`) > 0]],
        { ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES, ownerRef })
    txRows(query, [[UPDATE `synex_account_audit`
        SET `snapshot_json` = REPLACE(
            `snapshot_json`, JSON_QUOTE(?), JSON_QUOTE(?))
        WHERE JSON_VALID(`snapshot_json`) = 1
            AND OCTET_LENGTH(`snapshot_json`) <= ?
            AND LOCATE(JSON_QUOTE(?), `snapshot_json`) > 0]],
        { ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES, ownerRef })
    txRows(query, [[UPDATE `synex_account_outbox`
        SET `payload_json` = REPLACE(
            `payload_json`, JSON_QUOTE(?), JSON_QUOTE(?))
        WHERE JSON_VALID(`payload_json`) = 1
            AND OCTET_LENGTH(`payload_json`) <= ?
            AND LOCATE(JSON_QUOTE(?), `payload_json`) > 0]],
        { ownerRef, anonymousRef, MAX_DURABLE_JSON_BYTES, ownerRef })

    txRows(query, [[UPDATE `synex_account_operations`
        SET `caller_principal_ref` = ?
        WHERE `caller_principal_kind` = ? AND `caller_principal_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_ledger_transactions`
        SET `actor_ref` = ? WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_ledger_transactions`
        SET `reference_id` = ? WHERE `reference_type` = ? AND `reference_id` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_audit`
        SET `actor_ref` = ? WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_audit`
        SET `reference_id` = ? WHERE `reference_type` = ? AND `reference_id` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_holds`
        SET `actor_ref` = ?, `version` = `version` + 1
        WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_hold_events_v2`
        SET `actor_ref` = ? WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_hold_events`
        SET `actor_ref` = ? WHERE `actor_ref` = ?]],
        { anonymousRef, ownerRef })
    txRows(query, [[UPDATE `synex_ledger_reversals`
        SET `actor_ref` = ? WHERE `actor_ref` = ?]],
        { anonymousRef, ownerRef })
    txRows(query, [[UPDATE `synex_account_restrictions`
        SET `actor_ref` = ?, `version` = `version` + 1
        WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_policies`
        SET `actor_ref` = ?, `version` = `version` + 1
        WHERE `actor_kind` = ? AND `actor_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_economy_reconciliation_runs`
        SET `requested_by_ref` = ?
        WHERE `actor_kind` = ? AND `requested_by_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_financial_transaction_archive`
        SET `actor_ref` = ? WHERE `actor_ref` = ?]],
        { anonymousRef, ownerRef })
    txRows(query, [[UPDATE `synex_financial_transaction_archive_v2`
        SET `caller_principal_ref` = CASE
                WHEN `caller_principal_kind` = ? AND `caller_principal_ref` = ?
                    THEN ? ELSE `caller_principal_ref` END,
            `actor_ref` = CASE WHEN `actor_kind` = ? AND `actor_ref` = ?
                THEN ? ELSE `actor_ref` END,
            `reference_id` = CASE WHEN `reference_type` = ? AND `reference_id` = ?
                THEN ? ELSE `reference_id` END
        WHERE (`caller_principal_kind` = ? AND `caller_principal_ref` = ?)
            OR (`actor_kind` = ? AND `actor_ref` = ?)
            OR (`reference_type` = ? AND `reference_id` = ?)]], {
        ownerKind, ownerRef, anonymousRef, ownerKind, ownerRef, anonymousRef,
        ownerKind, ownerRef, anonymousRef,
        ownerKind, ownerRef, ownerKind, ownerRef, ownerKind, ownerRef
    })
    txRows(query, [[UPDATE `synex_account_outbox_retry_requests`
        SET `requested_by_ref` = ? WHERE `requested_by_ref` = ?]],
        { anonymousRef, ownerRef })
end

local function applyAnonymization(query, ownerKind, ownerRef, anonymousRef)
    txRows(query, [[UPDATE `synex_account_access_grants` AS `grant`
        LEFT JOIN `synex_account_owners` AS `grant_owner`
            ON `grant_owner`.`account_id` = `grant`.`account_id`
        SET `grant`.`principal_ref` = CASE
                WHEN `grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?
                    THEN ? ELSE `grant`.`principal_ref` END,
            `grant`.`granted_by_ref` = CASE WHEN `grant`.`granted_by_ref` = ?
                THEN ? ELSE `grant`.`granted_by_ref` END,
            `grant`.`revoked_by_ref` = CASE WHEN `grant`.`status` = 'active'
                THEN ? WHEN `grant`.`revoked_by_ref` = ?
                THEN ? ELSE `grant`.`revoked_by_ref` END,
            `grant`.`revocation_reason` = CASE WHEN `grant`.`status` = 'active'
                THEN CONCAT(?, '_deleted') ELSE `grant`.`revocation_reason` END,
            `grant`.`revoked_at` = COALESCE(`grant`.`revoked_at`, CURRENT_TIMESTAMP(6)),
            `grant`.`status` = 'revoked', `grant`.`active_marker` = NULL,
            `grant`.`version` = `grant`.`version` + 1
        WHERE (`grant`.`principal_kind` = ? AND `grant`.`principal_ref` = ?)
            OR `grant`.`granted_by_ref` = ? OR `grant`.`revoked_by_ref` = ?
            OR (`grant`.`status` = 'active' AND `grant_owner`.`owner_kind` = ?
                AND `grant_owner`.`owner_ref` = ?)]], {
        ownerKind, ownerRef, anonymousRef, ownerRef, anonymousRef,
        RESOURCE_PRINCIPAL, ownerRef, anonymousRef, ownerKind,
        ownerKind, ownerRef, ownerRef, ownerRef, ownerKind, ownerRef
    })
    txRows(query, [[UPDATE `synex_account_restrictions` AS `restriction`
        INNER JOIN `synex_account_owners` AS `owner`
            ON `owner`.`account_id` = `restriction`.`account_id`
        SET `restriction`.`status` = 'revoked',
            `restriction`.`active_marker` = NULL,
            `restriction`.`terminal_at` = CURRENT_TIMESTAMP(6),
            `restriction`.`termination_reason` = CONCAT(?, '_owner_deleted'),
            `restriction`.`version` = `restriction`.`version` + 1
        WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ?
            AND `restriction`.`status` = 'active']],
        { ownerKind, ownerKind, ownerRef })

    txRows(query, [[UPDATE `synex_accounts` AS `account`
        INNER JOIN `synex_account_owners` AS `owner`
            ON `owner`.`account_id` = `account`.`id`
        SET `account`.`status` = 'closed',
            `account`.`closed_at` = COALESCE(`account`.`closed_at`, CURRENT_TIMESTAMP(6)),
            `account`.`metadata_json` = '{}',
            `account`.`version` = `account`.`version` + 1
        WHERE `owner`.`owner_kind` = ? AND `owner`.`owner_ref` = ?]],
        { ownerKind, ownerRef })
    txRows(query, [[UPDATE `synex_account_owners`
        SET `owner_ref` = ? WHERE `owner_kind` = ? AND `owner_ref` = ?]],
        { anonymousRef, ownerKind, ownerRef })
end

local function claimOperation(query, operationName, idempotencyKey, fingerprintMaterial, traceId)
    local hashRow = txRows(query,
        'SELECT LOWER(SHA2(?, 256)) AS `request_fingerprint`',
        { fingerprintMaterial })[1]
    local fingerprint = hashRow and hashRow.request_fingerprint or nil
    if type(fingerprint) ~= 'string' or fingerprint:match('^[0-9a-f]+$') == nil
        or #fingerprint ~= 64 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The lifecycle request fingerprint is invalid.')
    end
    txRows(query, [[INSERT IGNORE INTO `synex_account_operations`
        (`idempotency_key`, `caller_resource`, `caller_principal_kind`,
            `caller_principal_ref`, `trace_id`, `operation_name`,
            `request_fingerprint`, `state`)
        VALUES (?, ?, 'resource', ?, ?, ?, ?, 'pending')]], {
        idempotencyKey, RESOURCE, RESOURCE_PRINCIPAL, traceId,
        operationName, fingerprint
    })
    local operation = txRows(query, [[SELECT `id`, `request_fingerprint`, `state`, `response_json`
        FROM `synex_account_operations`
        WHERE `caller_resource` = ?
            AND `caller_principal_kind` = 'resource' AND `caller_principal_ref` = ?
            AND `operation_name` = ? AND `idempotency_key` = ?
        FOR UPDATE]], { RESOURCE, RESOURCE_PRINCIPAL, operationName, idempotencyKey })[1]
    if not operation or operation.request_fingerprint ~= fingerprint then
        return nil, domainError('IDEMPOTENCY_CONFLICT',
            'The lifecycle operation identity conflicts with another request.')
    end
    if operation.state == 'completed' then
        local decoded, response = pcall(jsonDecode, operation.response_json)
        if not decoded or type(response) ~= 'table' then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The lifecycle operation receipt is invalid.')
        end
        return { id = operation.id, response = response, completed = true }, nil
    end
    if operation.state ~= 'pending' then
        return nil, domainError('OPERATION_IN_PROGRESS',
            'The lifecycle operation is not eligible for execution.', true)
    end
    return { id = operation.id, fingerprint = fingerprint, completed = false }, nil
end

local function completeOperation(query, operationId, responseJson)
    local updated = txRows(query, [[UPDATE `synex_account_operations`
        SET `state` = 'completed', `response_json` = ?,
            `completed_at` = CURRENT_TIMESTAMP(6)
        WHERE `id` = ? AND `state` = 'pending']], { responseJson, operationId })
    local affected = affectedRows(updated)
    if affected ~= nil and affected ~= 1 then
        return nil, domainError('CONCURRENT_MODIFICATION',
            'The lifecycle operation completion was not fenced.', true)
    end
    return true, nil
end

local function appendLifecycleEvent(query, operationId, aggregateId, eventType,
    traceId, responseJson)
    local eventId = uuidV4(random)
    txRows(query, [[INSERT INTO `synex_account_audit`
        (`event_id`, `operation_id`, `event_type`, `aggregate_id`,
            `source_resource`, `trace_id`, `actor_ref`, `actor_kind`, `snapshot_json`)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'resource', ?)]], {
        eventId, operationId, eventType, aggregateId,
        RESOURCE, traceId, RESOURCE_PRINCIPAL, responseJson
    })
    txRows(query, [[INSERT INTO `synex_account_outbox`
        (`event_id`, `aggregate_id`, `event_type`, `schema_version`,
            `trace_id`, `payload_json`)
        VALUES (?, ?, ?, 1, ?, ?)]], {
        eventId, aggregateId, eventType, traceId, responseJson
    })
end

function port:getOwnerLifecycleSummary(ownerKind, ownerRef)
    if (ownerKind ~= 'character' and ownerKind ~= 'group')
        or not Foundation.isSubjectId(ownerRef) then
        return nil, domainError('INVALID_OWNER',
            'The account lifecycle owner is invalid.')
    end
    return lifecycleState(function(sql, parameters)
        return many(sql, parameters)
    end, ownerKind, ownerRef, false)
end

function port:getCharacterLifecycleSummary(characterRef)
    return self:getOwnerLifecycleSummary('character', characterRef)
end

function port:getGroupLifecycleSummary(groupRef)
    if not Foundation.isPublicId(groupRef) then
        return nil, domainError('INVALID_GROUP',
            'The organization lifecycle reference is invalid.')
    end
    return lifecycleState(function(sql, parameters)
        return many(sql, parameters)
    end, 'group', groupRef, false)
end

function port:applyCharacterDeletion(planId, characterRef, anonymousRef)
    if type(planId) ~= 'string' or #planId < 8 or #planId > 64
        or planId:match('^[A-Za-z0-9_.:%-]+$') == nil
        or not Foundation.isSubjectId(characterRef) or not Foundation.isUuid(anonymousRef) then
        return nil, domainError('INVALID_DELETE_PLAN',
            'The character account deletion plan is invalid.')
    end
    local existing = one([[SELECT `anonymous_ref`, `account_count`, `grant_count`, `state`
        FROM `synex_account_character_deletions` WHERE `plan_id` = ?]], { planId })
    if existing and existing.state == 'completed' then
        if existing.anonymous_ref ~= anonymousRef then
            return nil, domainError('DELETE_PLAN_CONFLICT',
                'The character account deletion plan metadata changed.')
        end
        return {
            completed = true,
            anonymousRef = anonymousRef,
            accounts = tonumber(existing.account_count) or 0,
            grants = tonumber(existing.grant_count) or 0,
            ledgerHistory = 'retained',
            state = 'completed',
        }, nil
    end

    local result, domainFailure
    local committed, transactionError = withRetriableTransaction(function(query)
        result, domainFailure = nil, nil
        local journal = txRows(query, [[SELECT `anonymous_ref`, `account_count`,
                `grant_count`, `state`
            FROM `synex_account_character_deletions`
            WHERE `plan_id` = ? FOR UPDATE]], { planId })[1]
        if journal and journal.state == 'completed' then
            if journal.anonymous_ref ~= anonymousRef then
                domainFailure = domainError('DELETE_PLAN_CONFLICT',
                    'The character account deletion plan metadata changed.')
                return false
            end
            result = {
                completed = true,
                anonymousRef = anonymousRef,
                accounts = tonumber(journal.account_count) or 0,
                grants = tonumber(journal.grant_count) or 0,
                ledgerHistory = 'retained',
                state = 'completed',
            }
            return true
        end
        if journal and journal.anonymous_ref ~= anonymousRef then
            domainFailure = domainError('DELETE_PLAN_CONFLICT',
                'The character account deletion plan metadata changed.')
            return false
        end
        if not journal then
            txRows(query, [[INSERT INTO `synex_account_character_deletions`
                (`plan_id`, `anonymous_ref`, `state`) VALUES (?, ?, 'pending')]],
                { planId, anonymousRef })
        end
        local fingerprintMaterial = table.concat({
            'character', tostring(#characterRef), characterRef,
            tostring(#anonymousRef), anonymousRef,
            tostring(#planId), planId,
        }, ':')
        local operation
        operation, domainFailure = claimOperation(query, 'character_delete',
            'character-delete:' .. planId, fingerprintMaterial,
            validTraceId(planId) and planId or nil)
        if not operation then return false end
        if operation.completed then
            domainFailure = domainError('INTEGRITY_VIOLATION',
                'The character deletion receipt is complete while its journal is pending.')
            return false
        end

        local state
        state, domainFailure = lifecycleState(query, 'character', characterRef, true)
        if not state then return false end
        if state.nonterminalHolds > 0 then
            domainFailure = domainError('CHARACTER_ACCOUNTS_HAVE_HOLDS',
                'Character accounts still have active holds.', true)
            return false
        end
        if state.nonzeroAccounts > 0 then
            domainFailure = domainError('CHARACTER_ACCOUNTS_HAVE_BALANCE',
                'Character account balances must be transferred before deletion.')
            return false
        end

        applyAnonymization(query, 'character', characterRef, anonymousRef)
        anonymizeReferences(query, 'character', characterRef, anonymousRef)
        result = {
            completed = true,
            anonymousRef = anonymousRef,
            accounts = state.accounts,
            grants = state.activeGrants,
            ledgerHistory = 'retained',
            state = 'completed',
        }
        local responseJson = jsonEncode(result)
        if type(responseJson) ~= 'string' or #responseJson > 4096 then
            domainFailure = domainError('RESPONSE_TOO_LARGE',
                'The character account deletion receipt is invalid.')
            return false
        end
        appendLifecycleEvent(query, operation.id, anonymousRef,
            'synex.accounts.character.anonymized',
            validTraceId(planId) and planId or nil, responseJson)
        local completed
        completed, domainFailure = completeOperation(query, operation.id, responseJson)
        if not completed then return false end
        local updated = txRows(query, [[UPDATE `synex_account_character_deletions`
            SET `account_count` = ?, `grant_count` = ?, `state` = 'completed',
                `completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `plan_id` = ? AND `anonymous_ref` = ? AND `state` = 'pending']],
            { state.accounts, state.activeGrants, planId, anonymousRef })
        local changed = affectedRows(updated)
        if changed ~= nil and changed ~= 1 then
            domainFailure = domainError('CONCURRENT_MODIFICATION',
                'The character account deletion journal was not fenced.', true)
            return false
        end
        return true
    end, {
        maximumAttempts = 3,
        traceId = planId,
        shouldRetry = function(_, _, failureKind)
            return domainFailure == nil
                and (failureKind == 'deadlock' or failureKind == 'lock_timeout')
        end,
    })
    if committed then return result, nil end
    return nil, domainFailure or transactionError
end

local groupHelpers = {
    Foundation = Foundation,
    domainError = domainError,
    jsonEncode = jsonEncode,
    jsonDecode = jsonDecode,
    withRetriableTransaction = withRetriableTransaction,
    RESOURCE = RESOURCE,
    txRows = txRows,
    affectedRows = affectedRows,
    validTraceId = validTraceId,
    decimalIsZero = decimalIsZero,
    lifecycleState = lifecycleState,
    anonymizeReferences = anonymizeReferences,
    applyAnonymization = applyAnonymization,
    claimOperation = claimOperation,
    completeOperation = completeOperation,
    appendLifecycleEvent = appendLifecycleEvent,
}
require('server.persistence.lifecycle_groups')(port, groupHelpers)

end
