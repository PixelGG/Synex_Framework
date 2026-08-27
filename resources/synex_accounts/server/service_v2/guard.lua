return function(service, runtime)
    local Foundation = runtime.Foundation
    local domainError = runtime.domainError
    local reportUnexpectedError = runtime.reportUnexpectedError
    local errorSink = runtime.errorSink
    local audit = runtime.audit

    local mutating = {
        currency_register = true, register_currency = true, currency_update = true,
        create = true, freeze = true, unfreeze = true, close = true,
        transfer = true, transfer_v2 = true, debit = true, credit = true,
        mint = true, mint_v2 = true, burn = true, burn_v2 = true, post = true,
        hold_create = true, create_hold = true, hold_capture = true, capture_hold = true,
        hold_release = true, release_hold = true, transaction_reverse = true,
        reverse = true, transaction_refund = true, access_role_create = true,
        create_access_role = true, access_grant = true, grant_access = true,
        access_revoke = true, revoke_access = true, policy_set = true,
        restriction_create = true, restriction_revoke = true,
        reason_register = true, integrity_reconcile = true, run_reconciliation = true,
    }
    local policyFailures = {
        MINIMUM_BALANCE_VIOLATION = true,
        MAXIMUM_BALANCE_VIOLATION = true,
        TRANSFER_LIMIT_EXCEEDED = true,
        DAILY_LIMIT_EXCEEDED = true,
        OPERATION_NOT_ALLOWED = true,
    }
    local legacyFinancial = {
        transfer = true, debit = true, credit = true, mint = true, burn = true,
    }
    local function remapError(operation, operationError)
        if type(operationError) ~= 'table' or type(operationError.code) ~= 'string' then
            return operationError
        end
        local code = operationError.code
        local mapped = ({
            DATABASE_RESULT_INVALID = 'DATABASE_ERROR',
            EVENT_AGGREGATE_INVALID = 'DATABASE_ERROR',
            RESPONSE_TOO_LARGE = 'DATABASE_ERROR',
        })[code]
        if operation == 'create' and code == 'SYSTEM_ACCOUNT_EXISTS' then
            mapped = 'VALIDATION_FAILED'
        elseif operation == 'post' and code == 'LEDGER_UNBALANCED'
            or operation == 'transaction_refund' and code == 'LEDGER_UNBALANCED' then
            mapped = 'TRANSACTION_UNBALANCED'
        elseif (operation == 'mint_v2' or operation == 'burn_v2')
            and code == 'SYSTEM_TOPOLOGY_UNAVAILABLE' then
            mapped = 'CURRENCY_TOPOLOGY_INVALID'
        elseif (operation == 'transfer_v2' or operation == 'post'
                or operation == 'mint_v2' or operation == 'burn_v2')
            and policyFailures[code] then
            mapped = 'POLICY_VIOLATION'
        elseif legacyFinancial[operation] then
            if code == 'ACCOUNT_RESTRICTED' or code == 'ACCOUNT_ACCESS_DENIED'
                or policyFailures[code] then
                mapped = 'ACCOUNT_UNAVAILABLE'
            elseif code == 'AMOUNT_OUT_OF_RANGE' then
                mapped = 'VALIDATION_FAILED'
            elseif code == 'SYSTEM_TOPOLOGY_UNAVAILABLE' then
                mapped = 'INVALID_LEDGER_ROLE'
            end
        elseif operation == 'create_hold' then
            if code == 'INVALID_LEDGER_ROLE' or code == 'ACCOUNT_ACCESS_DENIED'
                or code == 'ACCOUNT_RESTRICTED' or policyFailures[code] then
                mapped = 'ACCOUNT_UNAVAILABLE'
            end
        elseif operation == 'hold_create' and policyFailures[code] then
            mapped = 'VALIDATION_FAILED'
        elseif operation == 'capture_hold' or operation == 'release_hold' then
            if code == 'HOLD_NOT_ACTIVE' or code == 'HOLD_ALREADY_TERMINAL'
                or code == 'HOLD_EXPIRED' then
                mapped = 'HOLD_TERMINAL'
            elseif code == 'ACCOUNT_ACCESS_DENIED' or code == 'ACCOUNT_RESTRICTED'
                or code == 'ACCOUNT_UNAVAILABLE' or code == 'CURRENCY_UNAVAILABLE'
                or code == 'INVALID_LEDGER_ROLE' or code == 'INSUFFICIENT_FUNDS'
                or policyFailures[code] then
                mapped = 'VALIDATION_FAILED'
            end
        elseif operation == 'hold_capture' then
            if code == 'CURRENCY_UNAVAILABLE' or code == 'INVALID_LEDGER_ROLE'
                or policyFailures[code] then
                mapped = 'ACCOUNT_UNAVAILABLE'
            end
        elseif operation == 'reverse' then
            if code == 'TRANSACTION_NOT_POSTED' or code == 'REVERSAL_OF_REVERSAL'
                or code == 'REVERSAL_NOT_ALLOWED' or code == 'ACCOUNT_ACCESS_DENIED'
                or code == 'ACCOUNT_RESTRICTED' or policyFailures[code] then
                mapped = 'REVERSAL_NOT_REVERSIBLE'
            end
        elseif operation == 'transaction_reverse' then
            if code == 'ACCOUNT_UNAVAILABLE' or code == 'ACCOUNT_RESTRICTED'
                or code == 'INSUFFICIENT_FUNDS' or policyFailures[code] then
                mapped = 'REVERSAL_NOT_ALLOWED'
            end
        elseif operation == 'transaction_refund' then
            if code == 'REFUND_POSTING_INVALID' then
                mapped = 'VALIDATION_FAILED'
            elseif code == 'ACCOUNT_UNAVAILABLE' or code == 'ACCOUNT_RESTRICTED'
                or code == 'INSUFFICIENT_FUNDS' or policyFailures[code] then
                mapped = 'TRANSACTION_NOT_REFUNDABLE'
            end
        elseif operation == 'create_access_role' or operation == 'get_access'
            or operation == 'get_hold' then
            if code == 'ACCOUNT_ACCESS_DENIED' then mapped = 'VALIDATION_FAILED' end
        elseif operation == 'grant_access' then
            if code == 'ACCOUNT_ACCESS_DENIED' or code == 'ACCOUNT_NOT_FOUND' then
                mapped = 'VALIDATION_FAILED'
            end
        elseif operation == 'revoke_access' then
            if code == 'ACCESS_GRANT_INACTIVE' then
                mapped = 'ACCESS_GRANT_REVOKED'
            elseif code == 'ACCOUNT_ACCESS_DENIED' or code == 'ACCOUNT_NOT_FOUND'
                or code == 'STALE_VERSION' then
                mapped = 'VALIDATION_FAILED'
            end
        elseif operation == 'get_snapshot' and code == 'ACCOUNT_ACCESS_DENIED' then
            mapped = 'VALIDATION_FAILED'
        elseif operation == 'get_integrity' and code == 'INTEGRITY_MODEL_NOT_FOUND' then
            mapped = 'DATABASE_ERROR'
        end
        if not mapped or mapped == code then return operationError end
        return domainError(mapped, operationError.message,
            operationError.retryable == true, operationError.details)
    end
    local guarded = {}
    for name, handler in pairs(service) do
        local operation, current = name, handler
        guarded[name] = function(request, context)
            local called, value, operationError = pcall(current, request, context)
            if not called then
                reportUnexpectedError(errorSink, 'synex_accounts', operation, context)
                return nil, domainError('DATABASE_ERROR', 'The account operation could not be completed.', true)
            end
            if value and mutating[operation] and audit and Foundation.isCallable(audit.append) then
                local targetId = type(value) == 'table' and (value.transaction_id
                    or value.account_id or value.hold_id or value.currency_id
                    or value.restriction_id or value.grant_id or value.role_id
                    or value.run_id) or nil
                local auditCalled, acknowledged, auditError = pcall(audit.append, {
                    action = 'accounts.' .. operation,
                    traceId = context and context.traceId,
                    targetType = 'financial_operation',
                    targetId = targetId or (context and context.traceId) or 'unavailable',
                    context = { outcome = 'committed', operation = operation },
                })
                if not auditCalled or not acknowledged then
                    errorSink({ operation = 'core_audit_forward',
                        traceId = context and context.traceId or 'unavailable',
                        code = type(auditError) == 'table' and auditError.code
                            or auditCalled and 'CORE_AUDIT_REJECTED' or 'CORE_AUDIT_EXCEPTION' })
                end
            end
            return value, remapError(operation, operationError)
        end
    end
    return guarded
end
