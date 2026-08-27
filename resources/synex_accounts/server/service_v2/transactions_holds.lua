return function(service, runtime)
    local Foundation = runtime.Foundation
    local Domain = runtime.Domain
    local MAX_MINOR = runtime.MAX_MINOR
    local domainError = runtime.domainError
    local db = runtime.db
    local shape = runtime.shape
    local positiveAmount = runtime.positiveAmount
    local optionalSafeInteger = runtime.optionalSafeInteger
    local uuid = runtime.uuid
    local currency = runtime.currency
    local metadata = runtime.metadata
    local mutationBase = runtime.mutationBase
    local readBase = runtime.readBase
    local invokeHookChain = runtime.invokeHookChain
    local mergeFields = runtime.mergeFields
    local principalFields = runtime.principalFields
    local provenanceFields = runtime.provenanceFields

    local function expectedSequence(value, field)
        if value == nil then return nil, nil end
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < 0 or value > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED',
                field .. ' must be a non-negative JavaScript-safe integer.')
        end
        return value, nil
    end

    local function transfer(request, context, operation, kind, sourceField, destinationField, builtinReason)
        local transferFields = {
            idempotency_key = true, source_account_id = true, destination_account_id = true,
            mint_account_id = true, burn_account_id = true, account_id = true,
            counterparty_account_id = true,
            amount_minor = true, refundable_minor = true, actor_ref = true,
        }
        local sequenceGuarded = builtinReason == nil and operation == 'transfer'
        if sequenceGuarded then
            transferFields.expected_source_sequence = true
            transferFields.expected_destination_sequence = true
        end
        local candidate, validationError = shape(request,
            mergeFields(provenanceFields, transferFields),
            { 'idempotency_key', sourceField, destinationField, 'amount_minor' })
        if not candidate then return nil, validationError end
        local sourceId, destinationId = candidate[sourceField], candidate[destinationField]
        local _, sourceError = uuid(sourceId, sourceField)
        if sourceError then return nil, sourceError end
        local _, destinationError = uuid(destinationId, destinationField)
        if destinationError then return nil, destinationError end
        local _, amountError = positiveAmount(candidate.amount_minor)
        if amountError then return nil, amountError end
        local expectedSource, expectedSourceError
        local expectedDestination, expectedDestinationError
        if sequenceGuarded then
            expectedSource, expectedSourceError = expectedSequence(
                candidate.expected_source_sequence, 'expected_source_sequence')
            if expectedSourceError then return nil, expectedSourceError end
            expectedDestination, expectedDestinationError = expectedSequence(
                candidate.expected_destination_sequence, 'expected_destination_sequence')
            if expectedDestinationError then return nil, expectedDestinationError end
        end
        local hooksApplied, hookError = invokeHookChain({
            'synex.accounts.before_transaction',
            operation == 'transfer' and 'synex.accounts.before_transfer' or nil,
        }, candidate, context)
        if not hooksApplied then return nil, hookError end
        candidate = hooksApplied
        local command, commandError = mutationBase(operation, candidate, context, {
            reasonRequired = builtinReason == nil, builtinReason = builtinReason,
        })
        if not command then return nil, commandError end
        command.sourceAccountId, command.destinationAccountId = sourceId, destinationId
        command.amountMinor, command.kind = candidate.amount_minor, kind
        if builtinReason == nil and kind == 'transfer' then
            if expectedSource ~= nil or expectedDestination ~= nil then
                command.expectedSequences = {}
                if expectedSource ~= nil then
                    command.expectedSequences[sourceId] = expectedSource
                end
                if expectedDestination ~= nil then
                    command.expectedSequences[destinationId] = expectedDestination
                end
            end
            if candidate.refundable_minor ~= nil then
                local _, refundableError = positiveAmount(
                    candidate.refundable_minor, 'refundable_minor')
                if refundableError or candidate.refundable_minor > candidate.amount_minor then
                    return nil, refundableError or domainError('VALIDATION_FAILED',
                        'refundable_minor cannot exceed amount_minor.')
                end
                command.refundableMinor = candidate.refundable_minor
                command.refundAnchorAccountId = sourceId
            end
            command.entries = {
                { accountId = sourceId, amountMinor = -candidate.amount_minor,
                    metadataJson = '{}' },
                { accountId = destinationId, amountMinor = candidate.amount_minor,
                    metadataJson = '{}' },
            }
            return db:postTransaction(command)
        end
        local response, responseError = db:post(command)
        if not response then return nil, responseError end
        if operation == 'transfer' then return response, nil end
        return {
            transaction_id = response.transaction_id,
            posting_id = response.posting_id,
            debit_minor = response.debit_minor,
            credit_minor = response.credit_minor,
        }, nil
    end

    function service.transfer(request, context)
        return transfer(request, context, 'transfer', 'transfer', 'source_account_id',
            'destination_account_id', 'synex_accounts.legacy.transfer')
    end
    function service.transfer_v2(request, context)
        return transfer(request, context, 'transfer', 'transfer', 'source_account_id',
            'destination_account_id', nil)
    end
    function service.debit(request, context)
        return transfer(request, context, 'debit', 'debit', 'account_id',
            'counterparty_account_id', 'synex_accounts.legacy.debit')
    end
    function service.credit(request, context)
        return transfer(request, context, 'credit', 'credit', 'counterparty_account_id',
            'account_id', 'synex_accounts.legacy.credit')
    end
    function service.mint(request, context)
        return transfer(request, context, 'mint', 'mint', 'mint_account_id',
            'account_id', 'synex_accounts.legacy.mint')
    end
    function service.burn(request, context)
        return transfer(request, context, 'burn', 'burn', 'account_id',
            'burn_account_id', 'synex_accounts.legacy.burn')
    end

    local function systemPost(request, context, operation, method)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, amount_minor = true,
        }), { 'idempotency_key', 'account_id', 'amount_minor', 'reason_code',
            'actor_kind', 'actor_ref' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id) then
            return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.')
        end
        local _, amountError = positiveAmount(candidate.amount_minor)
        if amountError then return nil, amountError end
        local _, hookError = invokeHookChain({ 'synex.accounts.before_transaction' },
            candidate, context)
        if hookError then return nil, hookError end
        local command, commandError = mutationBase(operation, candidate, context,
            { reasonRequired = true })
        if not command then return nil, commandError end
        command.accountId, command.amountMinor = candidate.account_id, candidate.amount_minor
        return method(db, command)
    end
    function service.mint_v2(request, context)
        return systemPost(request, context, 'mint', db.mintTransaction)
    end
    function service.burn_v2(request, context)
        return systemPost(request, context, 'burn', db.burnTransaction)
    end

    function service.post(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, postings = true, refundable_minor = true,
            refund_anchor_account_id = true, currency_code = true,
        }), { 'idempotency_key', 'currency_code', 'postings', 'reason_code' })
        if not candidate then return nil, validationError end
        local _, currencyError = currency(candidate.currency_code)
        if currencyError then return nil, currencyError end
        local postings = candidate.postings
        if type(postings) == 'table' then
            for _, posting in ipairs(postings) do
                if type(posting) == 'table' and posting.metadata_json ~= nil then
                    local normalized, metadataError = metadata(posting.metadata_json)
                    if not normalized then return nil, metadataError end
                    posting.metadata_json = normalized
                end
            end
        end
        local entries, postingError = Domain.validatePostings(postings)
        if not entries then return nil, postingError end
        local refundable, refundableError = optionalSafeInteger(candidate.refundable_minor,
            'refundable_minor', false)
        if refundableError then return nil, refundableError end
        if (refundable == nil) ~= (candidate.refund_anchor_account_id == nil) then
            return nil, domainError('VALIDATION_FAILED',
                'refundable_minor and refund_anchor_account_id must be supplied together.')
        end
        if candidate.refund_anchor_account_id and not Foundation.isUuid(candidate.refund_anchor_account_id) then
            return nil, domainError('VALIDATION_FAILED', 'refund_anchor_account_id must be a lowercase UUID.')
        end
        local _, hookError = invokeHookChain({ 'synex.accounts.before_transaction' },
            candidate, context)
        if hookError then return nil, hookError end
        local command, commandError = mutationBase('post', candidate, context, { reasonRequired = true })
        if not command then return nil, commandError end
        command.entries, command.kind, command.permission = entries, 'post', 'transfer'
        command.currencyCode = candidate.currency_code
        command.refundableMinor, command.refundAnchorAccountId = refundable,
            candidate.refund_anchor_account_id
        return db:postTransaction(command)
    end

    local function holdCreate(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, capture_account_id = true,
            amount_minor = true, expires_in_seconds = true, capture_policy = true,
            actor_ref = true,
        }), { 'idempotency_key', 'account_id', 'capture_account_id',
            'amount_minor', 'expires_in_seconds' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id) or not Foundation.isUuid(candidate.capture_account_id) then
            return nil, domainError('VALIDATION_FAILED', 'Hold account identifiers must be lowercase UUIDs.')
        end
        local _, amountError = positiveAmount(candidate.amount_minor)
        if amountError then return nil, amountError end
        if type(candidate.expires_in_seconds) ~= 'number'
            or math.type(candidate.expires_in_seconds) ~= 'integer'
            or candidate.expires_in_seconds < 1 or candidate.expires_in_seconds > 604800 then
            return nil, domainError('VALIDATION_FAILED', 'expires_in_seconds must be from 1 through 604800.')
        end
        if candidate.capture_policy ~= nil and candidate.capture_policy ~= 'single'
            and candidate.capture_policy ~= 'multiple' then
            return nil, domainError('VALIDATION_FAILED', 'capture_policy must be single or multiple.')
        end
        local isV2 = candidate.reason_code ~= nil or candidate.capture_policy ~= nil
        local command, commandError = mutationBase('hold_create', candidate, context, {
            reasonRequired = isV2, builtinReason = isV2 and nil or 'synex_accounts.hold',
        })
        if not command then return nil, commandError end
        command.accountId, command.captureAccountId = candidate.account_id,
            candidate.capture_account_id
        command.amountMinor, command.expiresInSeconds = candidate.amount_minor,
            candidate.expires_in_seconds
        command.capturePolicy = candidate.capture_policy or 'single'
        if isV2 then return db:createHoldV2(command) end
        return db:createHold(command)
    end
    service.hold_create = holdCreate
    service.create_hold = holdCreate

    function service.hold_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { hold_id = true }), { 'hold_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.hold_id) then
            return nil, domainError('VALIDATION_FAILED', 'hold_id must be a lowercase UUID.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        if candidate.actor_kind ~= nil then
            return db:getHoldV2(candidate.hold_id, accountAuthority)
        end
        return db:getHold(candidate.hold_id, accountAuthority)
    end
    service.get_hold = service.hold_get

    local function holdTransition(request, context, operation, method, legacyMethod)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, hold_id = true, amount_minor = true,
            expected_version = true, reason = true, actor_ref = true,
        }), { 'idempotency_key', 'hold_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.hold_id) then
            return nil, domainError('VALIDATION_FAILED', 'hold_id must be a lowercase UUID.')
        end
        local isV2 = candidate.reason_code ~= nil or candidate.amount_minor ~= nil
            or candidate.expected_version ~= nil
        if candidate.amount_minor ~= nil then
            local _, amountError = positiveAmount(candidate.amount_minor)
            if amountError then return nil, amountError end
        end
        if candidate.expected_version ~= nil and (type(candidate.expected_version) ~= 'number'
            or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 or candidate.expected_version > MAX_MINOR) then
            return nil, domainError('VALIDATION_FAILED',
                'expected_version must be a positive safe integer.')
        end
        if operation == 'hold_capture' then
            local _, hookError = invokeHookChain({
                'synex.accounts.before_transaction',
                'synex.accounts.before_hold_capture',
            }, candidate, context)
            if hookError then return nil, hookError end
        end
        local command, commandError = mutationBase(operation, candidate, context, {
            reasonRequired = isV2, builtinReason = isV2 and nil or 'synex_accounts.hold',
        })
        if not command then return nil, commandError end
        command.holdId, command.amountMinor, command.expectedVersion = candidate.hold_id,
            candidate.amount_minor, candidate.expected_version
        command.legacyProjection = not isV2
        if isV2 then return method(db, command) end
        return legacyMethod(db, command)
    end
    function service.hold_capture(request, context)
        return holdTransition(request, context, 'hold_capture',
            db.captureHoldV2, db.captureHold)
    end
    function service.hold_release(request, context)
        return holdTransition(request, context, 'hold_release',
            db.releaseHoldV2, db.releaseHold)
    end
    service.capture_hold = service.hold_capture
    service.release_hold = service.hold_release

    function service.transaction_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { transaction_id = true, account_id = true }), { 'transaction_id', 'account_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.transaction_id) or not Foundation.isUuid(candidate.account_id) then
            return nil, domainError('VALIDATION_FAILED',
                'transaction_id and account_id must be lowercase UUIDs.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getTransaction(candidate.transaction_id, accountAuthority, candidate.account_id)
    end

    function service.transaction_list(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            account_id = true, currency_code = true, reason_code = true,
            cursor = true, limit = true,
        }), { 'account_id' })
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:listTransactions({ accountId = candidate.account_id,
            currencyCode = candidate.currency_code, reasonCode = candidate.reason_code,
            cursor = candidate.cursor, limit = candidate.limit, authority = accountAuthority })
    end

    local function reverseTransaction(request, context, legacy)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, transaction_id = true, expected_version = true,
            reason = true, actor_ref = true,
        }), { 'idempotency_key', 'transaction_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.transaction_id) then
            return nil, domainError('VALIDATION_FAILED', 'transaction_id must be a lowercase UUID.')
        end
        if legacy and candidate.reason_code == nil then candidate.reason_code = 'synex_accounts.reversal' end
        local _, hookError = invokeHookChain({ 'synex.accounts.before_transaction' },
            candidate, context)
        if hookError then return nil, hookError end
        local command, commandError = mutationBase('reverse', candidate, context, {
            reasonRequired = not legacy, builtinReason = legacy and 'synex_accounts.reversal' or nil,
        })
        if not command then return nil, commandError end
        command.transactionId, command.expectedVersion, command.reason = candidate.transaction_id,
            candidate.expected_version, candidate.reason
        if legacy then return db:reverse(command) end
        return db:reverseTransaction(command)
    end
    function service.transaction_reverse(request, context) return reverseTransaction(request, context, false) end
    function service.reverse(request, context) return reverseTransaction(request, context, true) end

    function service.transaction_refund(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, transaction_id = true, postings = true,
            amount_minor = true, expected_version = true,
        }), { 'idempotency_key', 'transaction_id', 'postings', 'amount_minor', 'reason_code' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.transaction_id) then
            return nil, domainError('VALIDATION_FAILED', 'transaction_id must be a lowercase UUID.')
        end
        if type(candidate.postings) == 'table' then
            for _, posting in ipairs(candidate.postings) do
                if type(posting) == 'table' and posting.metadata_json ~= nil then
                    local normalized, metadataError = metadata(posting.metadata_json)
                    if not normalized then return nil, metadataError end
                    posting.metadata_json = normalized
                end
            end
        end
        local entries, postingError = Domain.validatePostings(candidate.postings)
        if not entries then return nil, postingError end
        local _, amountError = positiveAmount(candidate.amount_minor)
        if amountError then return nil, amountError end
        if type(candidate.expected_version) ~= 'number'
            or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 or candidate.expected_version > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED',
                'expected_version must be a positive safe integer.')
        end
        local _, hookError = invokeHookChain({ 'synex.accounts.before_transaction' },
            candidate, context)
        if hookError then return nil, hookError end
        local command, commandError = mutationBase('refund', candidate, context, { reasonRequired = true })
        if not command then return nil, commandError end
        command.transactionId, command.entries, command.amountMinor = candidate.transaction_id,
            entries, candidate.amount_minor
        command.expectedVersion = candidate.expected_version
        return db:refundTransaction(command)
    end
end
