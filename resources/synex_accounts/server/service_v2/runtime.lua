return function(Foundation, Domain)
local MAX_MINOR = Foundation.MAX_MINOR
local domainError = Foundation.domainError
local validateShape = Foundation.validateShape
local reportUnexpectedError = Foundation.reportUnexpectedError

local function createRuntime(deps)
    local db = assert(deps.db, 'synex_accounts v2 service requires deps.db')
    local jsonEncode = assert(deps.jsonEncode, 'synex_accounts v2 service requires deps.jsonEncode')
    local jsonDecode = assert(deps.jsonDecode, 'synex_accounts v2 service requires deps.jsonDecode')
    local errorSink = assert(type(deps.errorSink) == 'function' and deps.errorSink,
        'synex_accounts v2 service requires deps.errorSink')
    local hooks = deps.hooks
    local audit = deps.audit
    local checkResourceCapability = assert(
        Foundation.isCallable(deps.checkResourceCapability)
            and deps.checkResourceCapability,
        'synex_accounts v2 service requires a resource capability preflight')
    local canonicalEncode = Foundation.createCanonicalEncoder(jsonEncode)

    local currencyPattern = '^[a-z][a-z0-9_]*$'
    local rolePattern = '^[a-z][a-z0-9_]*$'
    local operationKeys = {
        post = true, deposit = true, withdraw = true, transfer = true,
        mint = true, burn = true, reversal = true, refund = true,
        ['hold.create'] = true, ['hold.capture'] = true, ['hold.release'] = true,
    }

    local function shape(request, allowed, required)
        if type(request) ~= 'table' or not Foundation.jsonContainerKind(request) then
            return nil, domainError('VALIDATION_FAILED', 'The account request must be a JSON object.')
        end
        local copiedOk, candidate = pcall(Foundation.copyPlain, request, {
            maximumDepth = 12, maximumNodes = 512, maximumStringBytes = 32768,
            preserveContainerKind = true,
        })
        if not copiedOk then
            return nil, domainError('VALIDATION_FAILED', 'The account request must contain bounded plain JSON data.')
        end
        local valid, validationError = validateShape(candidate, allowed, required)
        if not valid then return nil, validationError end
        return candidate, nil
    end

    local function validContext(context)
        return type(context) == 'table'
            and Domain.validResourceName(context.caller)
            and type(context.traceId) == 'string' and #context.traceId >= 8 and #context.traceId <= 64
            and context.traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
            and type(context.callerEpoch) == 'number'
            and math.type(context.callerEpoch) == 'integer' and context.callerEpoch >= 1
    end

    local function authority(context, request)
        if not validContext(context) then
            return nil, domainError('CALLER_CONTEXT_INVALID',
                'Account operations require caller-, epoch-, and trace-bound Core context.')
        end
        return Domain.context(context, request)
    end

    local function positiveAmount(value, field)
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < 1 or value > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED',
                (field or 'amount_minor') .. ' must be a positive JavaScript-safe integer.')
        end
        return value, nil
    end

    local function optionalSafeInteger(value, field, allowNegative)
        if value == nil then return nil, nil end
        local minimum = allowNegative and -MAX_MINOR or 1
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < minimum or value > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED',
                field .. ' is outside the supported JavaScript-safe integer range.')
        end
        return value, nil
    end

    local function uuid(value, field)
        if not Foundation.isUuid(value) then
            return nil, domainError('VALIDATION_FAILED', (field or 'identifier') .. ' must be a lowercase UUID.')
        end
        return value, nil
    end

    local function currency(value)
        if type(value) ~= 'string' or #value < 2 or #value > 16
            or value:match(currencyPattern) == nil then
            return nil, domainError('VALIDATION_FAILED', 'currency_code must be 2-16 lowercase ASCII characters.')
        end
        return value, nil
    end

    local function utf8(value, minimum, maximum, field, optional)
        if value == nil and optional then return nil, nil end
        local count = Foundation.characterLength(value)
        if count < minimum or count > maximum then
            return nil, domainError('VALIDATION_FAILED',
                ('%s must contain %d-%d valid UTF-8 characters.'):format(field, minimum, maximum))
        end
        return value, nil
    end

    local function metadata(value)
        if value == nil then return '{}', nil end
        if type(value) ~= 'string' or #value > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must be a JSON object no larger than 4096 bytes.')
        end
        local decodedOk, decoded = pcall(jsonDecode, value)
        if not decodedOk or type(decoded) ~= 'table'
            or Foundation.jsonContainerKind(decoded) ~= 'object' then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must contain a JSON object.')
        end
        local encodedOk, encoded = pcall(canonicalEncode, decoded)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json exceeds the supported shape or size.')
        end
        return encoded, nil
    end

    local function reference(candidate)
        if not Domain.validReferenceType(candidate.reference_type)
            or not Domain.validReferenceId(candidate.reference_id)
            or (candidate.reference_type == nil) ~= (candidate.reference_id == nil) then
            return nil, domainError('VALIDATION_FAILED',
                'reference_type and reference_id must form a valid optional pair.')
        end
        return true, nil
    end

    local function fingerprint(operation, candidate, accountAuthority)
        local material = {
            operation = operation,
            caller_principal_kind = accountAuthority.principalKind,
            caller_principal_ref = accountAuthority.principalRef,
            request = candidate,
        }
        local encodedOk, encoded = pcall(canonicalEncode, material)
        if not encodedOk or type(encoded) ~= 'string' or #encoded > 16384 then
            return nil, domainError('VALIDATION_FAILED', 'The operation fingerprint exceeds its supported bound.')
        end
        return encoded, nil
    end

    local function mutationBase(operation, candidate, context, options)
        options = options or {}
        if not Foundation.isUuid(candidate.idempotency_key) then
            return nil, domainError('VALIDATION_FAILED', 'idempotency_key must be a lowercase UUID.')
        end
        if context.idempotencyKey ~= nil and context.idempotencyKey ~= candidate.idempotency_key then
            return nil, domainError('VALIDATION_FAILED',
                'Request and service-context idempotency keys must match.')
        end
        local authorityCandidate = candidate
        if candidate.actor_kind == nil and candidate.actor_ref ~= nil then
            authorityCandidate = {}
            for key, value in pairs(candidate) do
                if key ~= 'actor_ref' then authorityCandidate[key] = value end
            end
        end
        local accountAuthority, authorityError = authority(context, authorityCandidate)
        if not accountAuthority then return nil, authorityError end
        local referenceValid, referenceError = reference(candidate)
        if not referenceValid then return nil, referenceError end
        local metadataJson, metadataError = metadata(candidate.metadata_json)
        if not metadataJson then return nil, metadataError end
        if options.reasonRequired and not Domain.validReasonCode(candidate.reason_code) then
            return nil, domainError('VALIDATION_FAILED', 'reason_code must be a registered namespaced reason.')
        end
        local requestFingerprint, fingerprintError = fingerprint(operation, candidate, accountAuthority)
        if not requestFingerprint then return nil, fingerprintError end
        return {
            operationName = operation,
            idempotencyKey = candidate.idempotency_key,
            fingerprint = requestFingerprint,
            authority = accountAuthority,
            reasonCode = candidate.reason_code or options.builtinReason,
            allowBuiltinReason = options.builtinReason ~= nil,
            reference = candidate.reference,
            referenceType = candidate.reference_type,
            referenceId = candidate.reference_id,
            metadataJson = metadataJson,
        }, nil
    end

    local function readBase(candidate, context)
        return authority(context, candidate)
    end

    local function runHook(name, candidate, context)
        if not hooks or not Foundation.isCallable(hooks.run) then return candidate, nil end
        local value, hookError = hooks.run(name, candidate, {
            traceId = context.traceId,
            metadata = {
                caller = context.caller,
                callerEpoch = context.callerEpoch,
            },
        })
        if not value then
            return nil, hookError or domainError('HOOK_REJECTED', 'An Accounts policy hook rejected the operation.')
        end
        local copiedOk, copied = pcall(Foundation.copyPlain, value, {
            maximumDepth = 12, maximumNodes = 512, maximumStringBytes = 32768,
            preserveContainerKind = true,
        })
        if not copiedOk then
            return nil, domainError('HOOK_REJECTED', 'An Accounts policy hook returned invalid data.')
        end
        return copied, nil
    end

    local function invokeHookChain(names, candidate, context)
        if not validContext(context) then
            return nil, domainError('CALLER_CONTEXT_INVALID',
                'Account policy hooks require caller-, epoch-, and trace-bound Core context.')
        end
        local originalOk, original = pcall(canonicalEncode, candidate)
        if not originalOk then
            return nil, domainError('VALIDATION_FAILED', 'The policy hook input is not canonical JSON.')
        end
        local current = candidate
        for _, name in ipairs(names or {}) do
            local nextValue, hookError = runHook(name, current, context)
            if not nextValue then
                return nil, domainError('VALIDATION_FAILED',
                    'A financial policy hook rejected the operation.', false, {
                        hook = name,
                        cause = type(hookError) == 'table' and hookError.code or nil,
                    })
            end
            local encodedOk, encoded = pcall(canonicalEncode, nextValue)
            if not encodedOk or encoded ~= original then
                return nil, domainError('VALIDATION_FAILED',
                    'Financial policy hooks are reject-only and cannot mutate ledger input.')
            end
            current = nextValue
        end
        return candidate, nil
    end

    local service = {}

    local principalFields = { actor_kind = true, actor_ref = true }
    local provenanceFields = {
        actor_kind = true, actor_ref = true, reason_code = true,
        reference = true, reference_type = true, reference_id = true,
        metadata_json = true,
    }
    local function mergeFields(...)
        local result = {}
        for index = 1, select('#', ...) do
            for key, value in pairs(select(index, ...)) do result[key] = value end
        end
        return result
    end

    return service, {
        Foundation = Foundation,
        Domain = Domain,
        MAX_MINOR = MAX_MINOR,
        domainError = domainError,
        reportUnexpectedError = reportUnexpectedError,
        db = db,
        errorSink = errorSink,
        audit = audit,
        checkResourceCapability = checkResourceCapability,
        shape = shape,
        positiveAmount = positiveAmount,
        optionalSafeInteger = optionalSafeInteger,
        uuid = uuid,
        currency = currency,
        utf8 = utf8,
        metadata = metadata,
        mutationBase = mutationBase,
        readBase = readBase,
        invokeHookChain = invokeHookChain,
        mergeFields = mergeFields,
        principalFields = principalFields,
        provenanceFields = provenanceFields,
        rolePattern = rolePattern,
        operationKeys = operationKeys,
    }
end

return createRuntime
end
