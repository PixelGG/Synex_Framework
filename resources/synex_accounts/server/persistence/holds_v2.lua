return function(port, context)
local Foundation = context.foundation
local Domain = context.domain
local Engine = context.engine
local domainError = context.domainError
local uuidV4 = context.uuidV4
local random = context.random
local one = context.one
local many = context.many
local txRows = context.txRows
local txOne = context.txOne
local jsonEncode = context.jsonEncode

local publicActorKinds = {
    system = true,
    resource = true,
    user = true,
    character = true,
    group = true,
}

local function publicTraceId(row)
    if type(row.trace_id) == 'string' and #row.trace_id >= 8 and #row.trace_id <= 64 then
        return row.trace_id
    end
    return 'legacy:' .. tostring(row.public_id)
end

local function publicActor(row)
    if publicActorKinds[row.actor_kind] and type(row.actor_ref) == 'string'
        and #row.actor_ref >= 2 and #row.actor_ref <= 128 then
        return row.actor_kind, row.actor_ref
    end
    if row.actor_kind == 'operator' and type(row.actor_ref) == 'string'
        and #row.actor_ref >= 2 and #row.actor_ref <= 128 then
        return 'user', row.actor_ref
    end
    return 'resource', 'synex_accounts'
end

local function holdRow(query, holdId)
    return txOne(query, [[SELECT `hold`.*, `source`.`public_id` AS `account_public_id`,
            `destination`.`public_id` AS `capture_account_public_id`,
            (`hold`.`expires_at` <= CURRENT_TIMESTAMP(6)) AS `is_expired`
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `hold`.`account_id`
        INNER JOIN `synex_accounts` AS `destination` ON `destination`.`id` = `hold`.`capture_account_id`
        WHERE `hold`.`public_id` = ? FOR UPDATE]], { holdId })
end

local function holdSequence(query, holdInternalId)
    local row = txOne(query, [[SELECT COALESCE(MAX(`sequence_no`), 0) + 1 AS `sequence_no`
        FROM `synex_account_hold_events_v2` WHERE `hold_id` = ?]], { holdInternalId })
    return tonumber(row and row.sequence_no) or 1
end

local function insertV2Event(query, hold, operationId, eventType, amountMinor,
    remainingMinor, transactionInternalId, command, snapshot)
    local eventId = uuidV4(random)
    txRows(query, [[INSERT INTO `synex_account_hold_events_v2`
        (`event_id`, `hold_id`, `operation_id`, `sequence_no`, `event_type`, `amount_minor`,
            `remaining_after_minor`, `ledger_transaction_id`, `reason_code`, `source_resource`,
            `trace_id`, `actor_kind`, `actor_ref`, `snapshot_json`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        eventId, hold.id, operationId, holdSequence(query, hold.id), eventType,
        amountMinor, remainingMinor, transactionInternalId, command.reasonCode,
        command.authority.callerResource, command.authority.traceId,
        command.authority.principalKind, command.authority.principalRef, jsonEncode(snapshot)
    })
    return eventId
end

local function validateAllowedOperation(query, accountId, operationMode, operationKey, label)
    if operationMode ~= 'allowlist' then return true, nil end
    if txOne(query, [[SELECT `operation_key`
        FROM `synex_account_policy_allowed_operations`
        WHERE `account_id` = ? AND `operation_key` = ?]], {
        accountId, operationKey
    }) then return true, nil end
    return nil, domainError('OPERATION_NOT_ALLOWED',
        ('The account policy does not allow %s.'):format(label))
end

local function validateHoldCreatePolicies(query, account, amountMinor)
    local restrictions = txRows(query, [[SELECT `restriction_kind`
        FROM `synex_account_restrictions`
        WHERE `account_id` = ? AND `status` = 'active'
            AND `valid_from` <= CURRENT_TIMESTAMP(6)
            AND (`valid_until` IS NULL OR `valid_until` > CURRENT_TIMESTAMP(6))]], {
        account.id
    })
    for _, restriction in ipairs(restrictions) do
        if restriction.restriction_kind == 'outgoing_blocked'
            or restriction.restriction_kind == 'all_blocked' then
            return nil, domainError('ACCOUNT_RESTRICTED',
                'An account restriction blocks the hold.')
        end
    end
    local policy = txOne(query, [[SELECT `minimum_balance_minor`,
            `single_transfer_limit_minor`, `daily_outgoing_limit_minor`, `operation_mode`
        FROM `synex_account_policies` WHERE `account_id` = ?]], { account.id })
    if not policy then return true, nil end
    local minimum = policy.minimum_balance_minor ~= nil
        and tonumber(policy.minimum_balance_minor) or nil
    local single = policy.single_transfer_limit_minor ~= nil
        and tonumber(policy.single_transfer_limit_minor) or nil
    local daily = policy.daily_outgoing_limit_minor ~= nil
        and tonumber(policy.daily_outgoing_limit_minor) or nil
    if minimum and account.available_minor - amountMinor < minimum then
        return nil, domainError('MINIMUM_BALANCE_VIOLATION',
            'The hold would violate the account minimum balance policy.')
    end
    if single and amountMinor > single then
        return nil, domainError('TRANSFER_LIMIT_EXCEEDED',
            'The hold exceeds the account single transaction limit.')
    end
    if daily then
        local usage = txOne(query, [[SELECT `outgoing_minor`
            FROM `synex_account_policy_daily_usage`
            WHERE `account_id` = ? AND `usage_date` = UTC_DATE() FOR UPDATE]], { account.id })
        if (tonumber(usage and usage.outgoing_minor) or 0) + amountMinor > daily then
            return nil, domainError('DAILY_LIMIT_EXCEEDED',
                'The hold exceeds the account daily outgoing limit.')
        end
    end
    return validateAllowedOperation(query, account.id, policy.operation_mode,
        'hold.create', 'hold creation')
end

function port:createHoldV2(command)
    local holdId = uuidV4(random)
    return Engine:mutation(command.operationName or 'hold_create', command, function(query, operationId)
        local accounts, accountError = Engine:loadAccounts(query,
            { command.accountId, command.captureAccountId })
        if not accounts then return nil, accountError end
        local source, destination = accounts[command.accountId], accounts[command.captureAccountId]
        if source.status ~= 'active' or destination.status ~= 'active' then
            return nil, domainError('ACCOUNT_UNAVAILABLE', 'Hold accounts must be active.')
        end
        if source.currency_status ~= 'active' or destination.currency_status ~= 'active' then
            return nil, domainError('ACCOUNT_UNAVAILABLE',
                'Hold accounts require an active currency.')
        end
        if source.currency_id ~= destination.currency_id then
            return nil, domainError('CURRENCY_MISMATCH', 'Hold accounts must use the same currency.')
        end
        if source.account_role ~= 'asset' or destination.account_role ~= 'asset' then
            return nil, domainError('INVALID_LEDGER_ROLE', 'Holds may use only asset accounts.')
        end
        local _, accessError = Engine:requireAccess(query, source,
            command.authority, 'hold.create')
        if accessError then return nil, accessError end
        local _, reasonError = Engine:requireReason(query, command.reasonCode,
            command.authority, command.allowBuiltinReason)
        if reasonError then return nil, reasonError end
        if source.available_minor < command.amountMinor then
            return nil, domainError('INSUFFICIENT_FUNDS', 'Available account funds are insufficient for the hold.')
        end
        local policiesValid, policyError = validateHoldCreatePolicies(
            query, source, command.amountMinor)
        if not policiesValid then return nil, policyError end
        txRows(query, [[INSERT INTO `synex_account_holds`
            (`public_id`, `operation_id`, `account_id`, `capture_account_id`, `amount_minor`,
                `capture_policy`, `state`, `captured_minor`, `released_minor`, `remaining_minor`,
                `reference_text`, `reason_code`, `source_resource`, `trace_id`, `actor_ref`, `actor_kind`,
                `metadata_json`, `version`, `expires_at`)
            VALUES (?, ?, ?, ?, ?, ?, 'active', 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, 1,
                TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)))]], {
            holdId, operationId, source.id, destination.id, command.amountMinor,
            command.capturePolicy, command.amountMinor, command.reference, command.reasonCode,
            command.authority.callerResource, command.authority.traceId,
            command.authority.principalRef, command.authority.principalKind,
            command.metadataJson or '{}', command.expiresInSeconds
        })
        local hold = holdRow(query, holdId)
        local eventSnapshot = { hold_id = holdId, state = 'active', amount_minor = command.amountMinor,
            remaining_minor = command.amountMinor, capture_policy = command.capturePolicy }
        txRows(query, [[INSERT INTO `synex_account_hold_events`
            (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`,
                `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
            VALUES (?, ?, 1, 'created', NULL, NULL, ?, ?)]], {
            uuidV4(random), hold.id, command.authority.principalRef, jsonEncode(eventSnapshot)
        })
        local v2EventId = insertV2Event(query, hold, operationId, 'created', 0,
            command.amountMinor, nil, command, eventSnapshot)
        local _, snapshotError = Engine:appendSnapshot(query, source, 'hold', holdId, source.booked_minor)
        if snapshotError then return nil, snapshotError end
        local response = {
            hold_id = holdId, account_id = command.accountId,
            capture_account_id = command.captureAccountId,
            amount_minor = command.amountMinor, captured_minor = 0,
            released_minor = 0, remaining_minor = command.amountMinor,
            currency_code = source.currency_code, state = 'active',
            capture_policy = command.capturePolicy, expires_in_seconds = command.expiresInSeconds,
            version = 1, event_id = v2EventId,
        }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.hold.created', holdId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:createHold(command)
    command.operationName = 'create_hold'
    command.capturePolicy = command.capturePolicy or 'single'
    command.reasonCode = command.reasonCode or 'synex_accounts.hold'
    command.allowBuiltinReason = true
    local response, responseError = self:createHoldV2(command)
    if not response then return nil, responseError end
    return {
        hold_id = response.hold_id,
        account_id = response.account_id,
        capture_account_id = response.capture_account_id,
        amount_minor = response.amount_minor,
        currency_code = response.currency_code,
        state = response.state,
        expires_in_seconds = response.expires_in_seconds,
    }, nil
end

function port:captureHoldV2(command)
    return Engine:mutation(command.operationName or 'hold_capture', command, function(query, operationId)
        local hold = holdRow(query, command.holdId)
        if not hold then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
        if tonumber(hold.is_expired) == 1
            and (hold.state == 'active' or hold.state == 'partially_captured') then
            return nil, domainError('HOLD_EXPIRED', 'The hold has expired.')
        end
        if command.expectedVersion and tonumber(hold.version) ~= command.expectedVersion then
            return nil, domainError('STALE_VERSION', 'The hold version changed.', true)
        end
        command.amountMinor = command.amountMinor or tonumber(hold.remaining_minor)
        local transition, transitionError = Domain.holdTransition(hold, 'capture', command.amountMinor)
        if not transition then return nil, transitionError end
        local entries = {
            { accountId = hold.account_public_id, amountMinor = -command.amountMinor, metadataJson = '{}' },
            { accountId = hold.capture_account_public_id, amountMinor = command.amountMinor, metadataJson = '{}' },
        }
        local holdEventId
        local response, postError = Engine:postWithin(query, operationId, command, {
            entries = entries,
            kind = 'hold_capture',
            permission = 'hold.capture',
            reservationReleaseByAccount = { [hold.account_public_id] = command.amountMinor },
            beforeSnapshots = function(innerQuery, transactionInternalId, transactionId)
                local terminal = transition.state == 'captured'
                txRows(innerQuery, [[UPDATE `synex_account_holds`
                    SET `state` = ?, `captured_minor` = `captured_minor` + ?,
                        `remaining_minor` = ?, `version` = `version` + 1,
                        `terminal_at` = CASE WHEN ? THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
                        `updated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `id` = ? AND `version` = ?]], {
                    transition.state, command.amountMinor, transition.remainingMinor,
                    terminal and 1 or 0, hold.id, hold.version
                })
                local eventType = terminal and 'captured' or 'partially_captured'
                local snapshot = { hold_id = command.holdId, state = transition.state,
                    amount_minor = command.amountMinor, remaining_minor = transition.remainingMinor,
                    transaction_id = transactionId, version = transition.nextVersion }
                holdEventId = insertV2Event(innerQuery, hold, operationId, eventType,
                    command.amountMinor, transition.remainingMinor, transactionInternalId, command, snapshot)
                if terminal then
                    txRows(innerQuery, [[INSERT IGNORE INTO `synex_account_hold_events`
                        (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`,
                            `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
                        VALUES (?, ?, 2, 'captured', 1, ?, ?, ?)]], {
                        uuidV4(random), hold.id, transactionInternalId,
                        command.authority.principalRef, jsonEncode(snapshot)
                    })
                end
                return true, nil
            end,
        })
        if not response then return nil, postError end
        response.hold_id = command.holdId
        response.state = transition.state
        response.captured_minor = command.amountMinor
        response.remaining_minor = transition.remainingMinor
        response.version = transition.nextVersion
        response.event_id = holdEventId
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.hold.captured', command.holdId, command, response)
        if eventError then return nil, eventError end
        response._internal_transaction_id = nil
        if not command.legacyProjection then
            response.posting_id = nil
            response.debit_account_id = nil
            response.credit_account_id = nil
            response.debit_minor = nil
            response.credit_minor = nil
        end
        return response, nil
    end)
end

function port:captureHold(command)
    command.operationName = 'capture_hold'
    command.reasonCode = command.reasonCode or 'synex_accounts.hold'
    command.allowBuiltinReason = true
    command.legacyProjection = true
    local response, responseError = self:captureHoldV2(command)
    if not response then return nil, responseError end
    return {
        hold_id = response.hold_id,
        state = response.state,
        transaction_id = response.transaction_id,
        posting_id = response.posting_id,
        debit_account_id = response.debit_account_id,
        credit_account_id = response.credit_account_id,
        amount_minor = response.amount_minor,
    }, nil
end

function port:releaseHoldV2(command)
    return Engine:mutation(command.operationName or 'hold_release', command, function(query, operationId)
        local hold = holdRow(query, command.holdId)
        if not hold then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
        if tonumber(hold.is_expired) == 1
            and (hold.state == 'active' or hold.state == 'partially_captured') then
            return nil, domainError('HOLD_EXPIRED', 'The hold has expired.')
        end
        if command.expectedVersion and tonumber(hold.version) ~= command.expectedVersion then
            return nil, domainError('STALE_VERSION', 'The hold version changed.', true)
        end
        local transition, transitionError = Domain.holdTransition(hold, 'release')
        if not transition then return nil, transitionError end
        local accounts, accountError = Engine:loadAccounts(query, { hold.account_public_id })
        if not accounts then return nil, accountError end
        local source = accounts[hold.account_public_id]
        local _, accessError = Engine:requireAccess(query, source, command.authority, 'hold.release')
        if accessError then return nil, accessError end
        local _, reasonError = Engine:requireReason(query, command.reasonCode,
            command.authority, command.allowBuiltinReason)
        if reasonError then return nil, reasonError end
        local policy = txOne(query, [[SELECT `operation_mode`
            FROM `synex_account_policies` WHERE `account_id` = ?]], { source.id })
        local operationAllowed, policyError = validateAllowedOperation(
            query, source.id, policy and policy.operation_mode, 'hold.release', 'hold release')
        if not operationAllowed then return nil, policyError end
        txRows(query, [[UPDATE `synex_account_holds`
            SET `state` = 'released', `released_minor` = `released_minor` + `remaining_minor`,
                `remaining_minor` = 0, `version` = `version` + 1,
                `terminal_at` = CURRENT_TIMESTAMP(6), `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `id` = ? AND `version` = ?]], { hold.id, hold.version })
        local snapshot = { hold_id = command.holdId, state = 'released',
            released_minor = transition.releasedMinor, remaining_minor = 0,
            version = transition.nextVersion }
        local eventId = insertV2Event(query, hold, operationId, 'released',
            transition.releasedMinor, 0, nil, command, snapshot)
        txRows(query, [[INSERT IGNORE INTO `synex_account_hold_events`
            (`event_id`, `hold_id`, `sequence_no`, `event_type`, `terminal_marker`,
                `ledger_transaction_id`, `actor_ref`, `snapshot_json`)
            VALUES (?, ?, 2, 'released', 1, NULL, ?, ?)]], {
            uuidV4(random), hold.id, command.authority.principalRef, jsonEncode(snapshot)
        })
        local _, snapshotError = Engine:appendSnapshot(query, source, 'hold',
            command.holdId, source.booked_minor)
        if snapshotError then return nil, snapshotError end
        local response = { hold_id = command.holdId, account_id = hold.account_public_id,
            state = 'released', released_minor = transition.releasedMinor,
            amount_minor = transition.releasedMinor,
            remaining_minor = 0, version = transition.nextVersion, event_id = eventId }
        local _, eventError = Engine:writeEvent(query, operationId,
            'synex.accounts.hold.released', command.holdId, command, response)
        if eventError then return nil, eventError end
        return response, nil
    end)
end

function port:releaseHold(command)
    command.operationName = 'release_hold'
    command.reasonCode = command.reasonCode or 'synex_accounts.hold'
    command.allowBuiltinReason = true
    local response, responseError = self:releaseHoldV2(command)
    if not response then return nil, responseError end
    return {
        hold_id = response.hold_id,
        state = response.state,
        account_id = response.account_id,
        amount_minor = response.amount_minor,
    }, nil
end

function port:getHoldV2(holdId, authority)
    local row = one([[SELECT `hold`.*, `source`.`public_id` AS `account_id`,
            `destination`.`public_id` AS `capture_account_id`, `currency`.`currency_code`,
            `event`.`event_id`, `event`.`occurred_at` AS `event_occurred_at`,
            (`hold`.`expires_at` <= CURRENT_TIMESTAMP(6)) AS `is_expired`
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_accounts` AS `source` ON `source`.`id` = `hold`.`account_id`
        INNER JOIN `synex_accounts` AS `destination` ON `destination`.`id` = `hold`.`capture_account_id`
        INNER JOIN `synex_currencies` AS `currency` ON `currency`.`id` = `source`.`currency_id`
        INNER JOIN `synex_account_hold_events_v2` AS `event` ON `event`.`hold_id` = `hold`.`id`
            AND `event`.`sequence_no` = (SELECT MAX(`latest`.`sequence_no`)
                FROM `synex_account_hold_events_v2` AS `latest` WHERE `latest`.`hold_id` = `hold`.`id`)
        WHERE `hold`.`public_id` = ?]], { holdId })
    if not row then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
    local scopedAccount, accountError = self:getAccount(
        row.account_id, authority, 'balance.read')
    if not scopedAccount then return nil, accountError end
    local effectiveState = row.state
    local remaining, released = tonumber(row.remaining_minor), tonumber(row.released_minor)
    if (effectiveState == 'active' or effectiveState == 'partially_captured')
        and tonumber(row.is_expired) == 1 then
        effectiveState = 'expired'
        released = released + remaining
        remaining = 0
    end
    local actorKind, actorRef = publicActor(row)
    return {
        hold_id = row.public_id, account_id = row.account_id,
        capture_account_id = row.capture_account_id, currency_code = row.currency_code,
        amount_minor = tonumber(row.amount_minor), captured_minor = tonumber(row.captured_minor),
        released_minor = released, remaining_minor = remaining, state = effectiveState,
        capture_policy = row.capture_policy, reason_code = row.reason_code,
        source_resource = row.source_resource, trace_id = publicTraceId(row),
        actor_kind = actorKind, actor_ref = actorRef,
        metadata_json = row.metadata_json, reference = row.reference_text,
        expires_at = tostring(row.expires_at), created_at = tostring(row.created_at),
        version = tonumber(row.version), event_id = row.event_id,
        event_occurred_at = tostring(row.event_occurred_at),
    }, nil
end

function port:getHold(holdId, authority)
    local response, responseError = self:getHoldV2(holdId, authority)
    if not response then return nil, responseError end
    return {
        hold_id = response.hold_id,
        account_id = response.account_id,
        capture_account_id = response.capture_account_id,
        amount_minor = response.amount_minor,
        state = response.state,
        metadata_json = response.metadata_json,
        expires_at = response.expires_at,
        created_at = response.created_at,
        event_id = response.event_id,
        event_occurred_at = response.event_occurred_at,
    }, nil
end

function port:expireHolds(maximum)
    maximum = math.max(1, math.min(tonumber(maximum) or 25, 100))
    local candidates = many([[SELECT `public_id`, `version`
        FROM `synex_account_holds`
        WHERE `state` IN ('active', 'partially_captured') AND `expires_at` <= CURRENT_TIMESTAMP(6)
        ORDER BY `expires_at` ASC, `id` ASC LIMIT ?]], { maximum })
    local report = { inspected = #candidates, expired = 0, skipped = 0, failed = 0 }
    for _, candidate in ipairs(candidates) do
        local command = {
            idempotencyKey = candidate.public_id,
            fingerprint = 'hold_expire|' .. candidate.public_id,
            operationName = 'hold_expire', holdId = candidate.public_id,
            reasonCode = 'synex_accounts.hold', allowBuiltinReason = true,
            metadataJson = '{}',
            authority = { callerResource = 'synex_accounts', principalKind = 'resource',
                principalRef = 'synex_accounts', traceId = uuidV4(random) },
        }
        local response = Engine:mutation('hold_expire', command, function(query, operationId)
            local hold = holdRow(query, candidate.public_id)
            if not hold then return nil, domainError('HOLD_NOT_FOUND', 'The hold does not exist.') end
            if hold.state ~= 'active' and hold.state ~= 'partially_captured' then
                return { hold_id = candidate.public_id, state = hold.state, skipped = true }, nil
            end
            if tonumber(hold.is_expired) ~= 1 then
                return { hold_id = candidate.public_id, state = hold.state, skipped = true }, nil
            end
            local accounts, accountError = Engine:loadAccounts(query, { hold.account_public_id })
            if not accounts then return nil, accountError end
            local source = accounts[hold.account_public_id]
            local released = tonumber(hold.remaining_minor)
            txRows(query, [[UPDATE `synex_account_holds`
                SET `state` = 'expired', `released_minor` = `released_minor` + `remaining_minor`,
                    `remaining_minor` = 0, `version` = `version` + 1,
                    `terminal_at` = `expires_at`, `updated_at` = CURRENT_TIMESTAMP(6)
                WHERE `id` = ? AND `version` = ?]], { hold.id, hold.version })
            local snapshot = { hold_id = candidate.public_id, state = 'expired',
                released_minor = released, remaining_minor = 0, version = tonumber(hold.version) + 1 }
            insertV2Event(query, hold, operationId, 'expired', released, 0, nil, command, snapshot)
            local _, snapshotError = Engine:appendSnapshot(query, source, 'hold',
                candidate.public_id, source.booked_minor)
            if snapshotError then return nil, snapshotError end
            local _, eventError = Engine:writeEvent(query, operationId,
                'synex.accounts.hold.expired', candidate.public_id, command, snapshot)
            if eventError then return nil, eventError end
            return snapshot, nil
        end)
        if response and response.skipped then report.skipped = report.skipped + 1
        elseif response then report.expired = report.expired + 1
        else report.failed = report.failed + 1 end
    end
    return report, nil
end

end
