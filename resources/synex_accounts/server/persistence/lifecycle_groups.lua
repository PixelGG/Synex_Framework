return function(port, helpers)
local Foundation = helpers.Foundation
local domainError = helpers.domainError
local jsonEncode = helpers.jsonEncode
local jsonDecode = helpers.jsonDecode
local withRetriableTransaction = helpers.withRetriableTransaction
local RESOURCE = helpers.RESOURCE
local txRows = helpers.txRows
local affectedRows = helpers.affectedRows
local validTraceId = helpers.validTraceId
local decimalIsZero = helpers.decimalIsZero
local lifecycleState = helpers.lifecycleState
local anonymizeReferences = helpers.anonymizeReferences
local applyAnonymization = helpers.applyAnonymization
local claimOperation = helpers.claimOperation
local completeOperation = helpers.completeOperation
local appendLifecycleEvent = helpers.appendLifecycleEvent

function port:applyGroupDeletion(command)
    if type(command) ~= 'table'
        or type(command.planId) ~= 'string' or #command.planId < 1
        or #command.planId > 47 or command.planId:match('^[a-z0-9_]+$') == nil
        or type(command.actionId) ~= 'string' or #command.actionId < 8
        or #command.actionId > 64
        or command.actionId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
        or not Foundation.isPublicId(command.groupRef)
        or not Foundation.isUuid(command.anonymousRef)
        or command.decision ~= 'anonymize'
        or type(command.reason) ~= 'string' or #command.reason < 1
        or #command.reason > 512 or not validTraceId(command.traceId) then
        return nil, domainError('INVALID_DELETION_REQUEST',
            'The organization account deletion request is invalid.')
    end

    local result, domainFailure
    local committed, transactionError = withRetriableTransaction(function(query)
        result, domainFailure = nil, nil
        local fingerprintMaterial = table.concat({
            'group', tostring(#command.planId), command.planId,
            tostring(#command.actionId), command.actionId,
            tostring(#command.groupRef), command.groupRef,
            tostring(#command.anonymousRef), command.anonymousRef,
            tostring(#command.reason), command.reason,
        }, ':')
        local fingerprintRow = txRows(query,
            'SELECT LOWER(SHA2(?, 256)) AS `request_fingerprint`',
            { fingerprintMaterial })[1]
        local fingerprint = fingerprintRow and fingerprintRow.request_fingerprint or nil
        if type(fingerprint) ~= 'string' or #fingerprint ~= 64
            or fingerprint:match('^[0-9a-f]+$') == nil then
            domainFailure = domainError('DATABASE_RESULT_INVALID',
                'The organization deletion request fingerprint is invalid.')
            return false
        end

        local journal = txRows(query, [[SELECT `action_id`, `group_ref`, `anonymous_ref`,
                `request_fingerprint`, `decision`, `state`, `account_count`, `grant_count`,
                `response_json`
            FROM `synex_account_group_deletions`
            WHERE `plan_id` = ? FOR UPDATE]], { command.planId })[1]
        if journal then
            if journal.action_id ~= command.actionId or journal.group_ref ~= command.groupRef
                or journal.anonymous_ref ~= command.anonymousRef
                or journal.request_fingerprint ~= fingerprint
                or journal.decision ~= command.decision then
                domainFailure = domainError('DELETION_PLAN_CONFLICT',
                    'The organization account deletion plan metadata changed.')
                return false
            end
            if journal.state == 'completed' then
                local decoded, previous = pcall(jsonDecode, journal.response_json)
                if not decoded or type(previous) ~= 'table' then
                    domainFailure = domainError('DATABASE_RESULT_INVALID',
                        'The organization account deletion receipt is invalid.')
                    return false
                end
                result = previous
                return true
            end
            if journal.state ~= 'pending' then
                domainFailure = domainError('DELETION_PLAN_CONFLICT',
                    'The organization account deletion plan is terminal.')
                return false
            end
        else
            local actionConflict = txRows(query, [[SELECT `plan_id`
                FROM `synex_account_group_deletions`
                WHERE `action_id` = ? FOR UPDATE]], { command.actionId })[1]
            if actionConflict then
                domainFailure = domainError('DELETION_PLAN_CONFLICT',
                    'The organization deletion action is already owned by another plan.')
                return false
            end
        end

        local operation
        operation, domainFailure = claimOperation(query, 'group_delete',
            command.actionId, fingerprintMaterial, command.traceId)
        if not operation then return false end
        if operation.completed then
            domainFailure = domainError('INTEGRITY_VIOLATION',
                'The organization deletion receipt is complete while its journal is pending.')
            return false
        end

        local state
        state, domainFailure = lifecycleState(query, 'group', command.groupRef, true)
        if not state then return false end
        if state.nonterminalHolds > 0 then
            domainFailure = domainError('GROUP_ACCOUNTS_HAVE_HOLDS',
                'Organization accounts still have active holds.', true)
            return false
        end
        if state.nonzeroAccounts > 0 then
            domainFailure = domainError('GROUP_ACCOUNTS_REQUIRE_TRANSFER',
                'Organization account balances must be transferred before deletion.')
            return false
        end
        if not decimalIsZero(state.bookedMinorTotal) then
            domainFailure = domainError('INTEGRITY_VIOLATION',
                'The organization account balance aggregate is inconsistent.')
            return false
        end

        if not journal then
            txRows(query, [[INSERT INTO `synex_account_group_deletions`
                (`plan_id`, `action_id`, `group_ref`, `anonymous_ref`,
                    `request_fingerprint`, `decision`, `state`, `account_count`,
                    `nonzero_account_count`, `grant_count`, `nonterminal_hold_count`,
                    `booked_minor_total`, `reason_text`, `source_resource`, `trace_id`)
                VALUES (?, ?, ?, ?, ?, 'anonymize', 'pending', ?, ?, ?, ?, ?, ?, ?, ?)]], {
                command.planId, command.actionId, command.groupRef, command.anonymousRef,
                fingerprint, state.accounts, state.nonzeroAccounts, state.activeGrants,
                state.nonterminalHolds, state.bookedMinorTotal, command.reason,
                RESOURCE, command.traceId
            })
        end

        applyAnonymization(query, 'group', command.groupRef, command.anonymousRef)
        anonymizeReferences(query, 'group', command.groupRef, command.anonymousRef)
        result = {
            completed = true,
            decision = 'anonymize',
            anonymousRef = command.anonymousRef,
            accounts = state.accounts,
            grants = state.activeGrants,
            ledgerHistory = 'retained',
            state = 'completed',
        }
        local responseJson = jsonEncode(result)
        if type(responseJson) ~= 'string' or #responseJson > 4096 then
            domainFailure = domainError('RESPONSE_TOO_LARGE',
                'The organization account deletion receipt is invalid.')
            return false
        end
        appendLifecycleEvent(query, operation.id, command.anonymousRef,
            'synex.accounts.group.anonymized', command.traceId, responseJson)
        local completed
        completed, domainFailure = completeOperation(query, operation.id, responseJson)
        if not completed then return false end
        local updated = txRows(query, [[UPDATE `synex_account_group_deletions`
            SET `account_count` = ?, `nonzero_account_count` = ?, `grant_count` = ?,
                `nonterminal_hold_count` = ?, `booked_minor_total` = ?,
                `response_json` = ?, `failure_code` = NULL, `state` = 'completed',
                `version` = `version` + 1, `completed_at` = CURRENT_TIMESTAMP(6)
            WHERE `plan_id` = ? AND `action_id` = ? AND `state` = 'pending']], {
            state.accounts, state.nonzeroAccounts, state.activeGrants,
            state.nonterminalHolds, state.bookedMinorTotal, responseJson,
            command.planId, command.actionId
        })
        local changed = affectedRows(updated)
        if changed ~= nil and changed ~= 1 then
            domainFailure = domainError('CONCURRENT_MODIFICATION',
                'The organization account deletion journal was not fenced.', true)
            return false
        end
        return true
    end, {
        maximumAttempts = 3,
        traceId = command.traceId,
        shouldRetry = function(_, _, failureKind)
            return domainFailure == nil
                and (failureKind == 'deadlock' or failureKind == 'lock_timeout')
        end,
    })
    if committed then return result, nil end
    return nil, domainFailure or transactionError
end

end
