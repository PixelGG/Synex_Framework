return function(Foundation, Domain)
    return function(options)
        local database = options.database
        local outboxDispatcher = options.outboxDispatcher
        local coreAudit = options.coreAudit
        local runtimeErrorSink = options.runtimeErrorSink

        local function operatorRequest(request, allowed, required)
            if type(request) ~= 'table' or not Foundation.jsonContainerKind(request) then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'The Accounts operator request must be a JSON object.')
            end
            local copiedOk, candidate = pcall(Foundation.copyPlain, request, {
                maximumDepth = 3,
                maximumKeys = 8,
                maximumStringBytes = 256,
            })
            if not copiedOk then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'The Accounts operator request is invalid.')
            end
            local valid, validationError = Foundation.validateShape(
                candidate, allowed or {}, required or {})
            if not valid then return nil, validationError end
            return candidate, nil
        end

        local function operatorContext(context)
            if type(context) ~= 'table' or not Domain.validResourceName(context.caller)
                or type(context.callerEpoch) ~= 'number'
                or math.type(context.callerEpoch) ~= 'integer' or context.callerEpoch < 1
                or type(context.traceId) ~= 'string' or #context.traceId < 8
                or #context.traceId > 64
                or context.traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
                return nil, Foundation.domainError('CALLER_CONTEXT_INVALID',
                    'Accounts operator requests require caller-, epoch-, and trace-bound Core context.')
            end
            return true, nil
        end

        local function operatorRead(operation, context, handler)
            local called, value, operationError = pcall(handler)
            if called then return value, operationError end
            runtimeErrorSink({
                operation = operation,
                code = 'DATABASE_ERROR',
                traceId = type(context) == 'table' and context.traceId or 'unavailable',
            })
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The Accounts operator read could not be completed.', true)
        end

        local function normalizeOutboxRetryError(operationError)
            if type(operationError) ~= 'table' then
                return Foundation.domainError('DATABASE_ERROR',
                    'The account outbox retry could not be completed.', true)
            end
            local code = operationError.code
            if code == 'OUTBOX_RETRY_IDEMPOTENCY_CONFLICT' then
                code = 'IDEMPOTENCY_CONFLICT'
            elseif code == 'OUTBOX_RETRY_IN_PROGRESS' then
                code = 'OPERATION_IN_PROGRESS'
            elseif code == 'WRITE_CONFLICT' then
                code = 'OUTBOX_RETRY_FAILED'
            end
            if code == operationError.code then return operationError end
            return Foundation.domainError(code, operationError.message,
                operationError.retryable == true, operationError.details)
        end

        return {
            doctor = function(request, context)
                local _, requestError = operatorRequest(request, {}, {})
                if requestError then return nil, requestError end
                local _, contextError = operatorContext(context)
                if contextError then return nil, contextError end
                return operatorRead('doctor', context, function()
                    return database:doctorAccounts()
                end)
            end,
            inspect_transaction = function(request, context)
                local candidate, requestError = operatorRequest(request,
                    { transaction_id = true }, { 'transaction_id' })
                if not candidate then return nil, requestError end
                local _, contextError = operatorContext(context)
                if contextError then return nil, contextError end
                return operatorRead('inspect_transaction', context, function()
                    return database:inspectTransaction(candidate.transaction_id)
                end)
            end,
            inspect_account = function(request, context)
                local candidate, requestError = operatorRequest(request,
                    { account_id = true }, { 'account_id' })
                if not candidate then return nil, requestError end
                local _, contextError = operatorContext(context)
                if contextError then return nil, contextError end
                return operatorRead('inspect_account', context, function()
                    return database:inspectAccount(candidate.account_id)
                end)
            end,
            inspect_outbox = function(request, context)
                local candidate, requestError = operatorRequest(request,
                    { maximum = true }, {})
                if not candidate then return nil, requestError end
                local _, contextError = operatorContext(context)
                if contextError then return nil, contextError end
                if candidate.maximum ~= nil and (type(candidate.maximum) ~= 'number'
                    or math.type(candidate.maximum) ~= 'integer'
                    or candidate.maximum < 1 or candidate.maximum > 50) then
                    return nil, Foundation.domainError('VALIDATION_FAILED',
                        'The Accounts outbox inspection limit must be an integer from one through fifty.')
                end
                return operatorRead('inspect_outbox', context, function()
                    return outboxDispatcher:inspectDead({ maximum = candidate.maximum or 25 })
                end)
            end,
            outbox_retry = function(request, context)
                local candidate, requestError = operatorRequest(request, {
                    idempotency_key = true, event_id = true, reason = true,
                    actor_kind = true, actor_ref = true,
                }, { 'idempotency_key', 'event_id', 'reason', 'actor_kind', 'actor_ref' })
                if not candidate then return nil, requestError end
                local _, contextError = operatorContext(context)
                if contextError then return nil, contextError end
                if not Foundation.isUuid(candidate.idempotency_key)
                    or not Foundation.isUuid(candidate.event_id)
                    or type(candidate.reason) ~= 'string' or #candidate.reason < 1
                    or #candidate.reason > 256 or candidate.reason:match('%S') == nil
                    or candidate.reason:match('%c') ~= nil then
                    return nil, Foundation.domainError('VALIDATION_FAILED',
                        'The Accounts outbox retry request is invalid.')
                end
                local authority, authorityError = Domain.context(context, candidate)
                if not authority then return nil, authorityError end
                local called, value, operationError = pcall(function()
                    return outboxDispatcher:requestRetry({
                        eventId = candidate.event_id,
                        idempotencyKey = candidate.idempotency_key,
                        requestedByResource = authority.callerResource,
                        requestedByRef = authority.principalRef,
                        reason = candidate.reason,
                    })
                end)
                if not called then
                    runtimeErrorSink({ operation = 'outbox_retry', code = 'DATABASE_ERROR',
                        traceId = authority.traceId })
                    return nil, Foundation.domainError('DATABASE_ERROR',
                        'The account outbox retry could not be completed.', true)
                end
                if not value then return nil, normalizeOutboxRetryError(operationError) end
                local auditCalled, audited, auditError = pcall(coreAudit.append, {
                    action = 'accounts.outbox_retry',
                    traceId = authority.traceId,
                    targetType = 'outbox_event',
                    targetId = candidate.event_id,
                    context = {
                        outcome = 'accepted', operation = 'outbox_retry',
                        replayed = value.replayed == true,
                        retryRequestId = value.retryRequestId,
                    },
                })
                if not auditCalled or not audited then
                    runtimeErrorSink({ operation = 'core_audit_forward',
                        traceId = authority.traceId,
                        code = type(auditError) == 'table' and auditError.code
                            or auditCalled and 'CORE_AUDIT_REJECTED' or 'CORE_AUDIT_EXCEPTION' })
                end
                return {
                    retry_request_id = value.retryRequestId,
                    event_id = value.eventId,
                    accepted = true,
                    replayed = value.replayed == true,
                }, nil
            end,
        }
    end
end
