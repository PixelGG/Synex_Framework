return function(Foundation)
local Domain = {}
local MAX_MINOR = Foundation.MAX_MINOR

Domain.permissions = {
    ['balance.read'] = true,
    ['history.read'] = true,
    deposit = true,
    withdraw = true,
    transfer = true,
    ['hold.create'] = true,
    ['hold.capture'] = true,
    ['hold.release'] = true,
    ['access.read'] = true,
    ['access.manage'] = true,
    ['settings.manage'] = true,
    close = true,
}

Domain.permissionAliases = {
    view = 'balance.read',
    history = 'history.read',
    manage = 'access.manage',
}

Domain.operationPermissions = {
    balance_get = 'balance.read',
    balance_get_at = 'history.read',
    transaction_get = 'history.read',
    transaction_list = 'history.read',
    transfer = 'transfer',
    post = 'transfer',
    mint = 'deposit',
    burn = 'withdraw',
    hold_create = 'hold.create',
    hold_capture = 'hold.capture',
    hold_release = 'hold.release',
    access_get = 'access.read',
    access_check = 'access.read',
    access_explain = 'access.read',
    access_role_create = 'access.manage',
    access_grant = 'access.manage',
    access_revoke = 'access.manage',
    account_freeze = 'settings.manage',
    account_unfreeze = 'settings.manage',
    account_close = 'close',
    policy_get = 'settings.manage',
    policy_set = 'settings.manage',
    reverse = 'transfer',
    refund = 'transfer',
}

local function failure(code, message, retryable, details)
    return nil, Foundation.domainError(code, message, retryable, details)
end

function Domain.validReasonCode(value)
    if type(value) ~= 'string' or #value < 3 or #value > 96
        or value:sub(1, 1) == '.' or value:sub(-1) == '.' then return false end
    local count = 0
    for segment in value:gmatch('[^.]+') do
        if segment:match('^[a-z][a-z0-9_]*$') == nil then return false end
        count = count + 1
    end
    return count >= 2
end

function Domain.validResourceName(value)
    return type(value) == 'string' and #value >= 2 and #value <= 64
        and value:match('^synex_[a-z0-9_]+$') ~= nil
end

function Domain.validReferenceType(value)
    return value == nil or (type(value) == 'string' and #value >= 2 and #value <= 48
        and value:match('^[a-z][a-z0-9_.%-]*$') ~= nil)
end

function Domain.validReferenceId(value)
    return value == nil or (type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil)
end

function Domain.validPrincipal(kind, reference)
    if kind == 'resource' or kind == 'system' then
        return Domain.validResourceName(reference)
    end
    if kind == 'group' then return Foundation.isPublicId(reference) end
    if kind == 'user' or kind == 'character' then return Foundation.isSubjectId(reference) end
    return false
end

function Domain.context(context, request)
    if type(context) ~= 'table' or not Domain.validResourceName(context.caller)
        or type(context.traceId) ~= 'string' or #context.traceId < 8 or #context.traceId > 64
        or context.traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return failure('CALLER_CONTEXT_INVALID', 'The authoritative Core caller context is unavailable.')
    end
    local principalKind = type(request) == 'table' and request.actor_kind or nil
    local principalRef = type(request) == 'table' and request.actor_ref or nil
    if principalKind == nil and principalRef == nil then
        principalKind, principalRef = 'resource', context.caller
    elseif not Domain.validPrincipal(principalKind, principalRef) then
        return failure('VALIDATION_FAILED', 'The account principal is invalid.')
    elseif (principalKind == 'resource' or principalKind == 'system')
        and principalRef ~= context.caller then
        return failure('PRINCIPAL_SPOOFED',
            'A resource or system actor must match the authoritative caller.')
    end
    return {
        callerResource = context.caller,
        traceId = context.traceId,
        callerEpoch = context.callerEpoch,
        contract = context.contract,
        contractVersion = context.version,
        principalKind = principalKind,
        principalRef = principalRef,
    }, nil
end

function Domain.validatePostings(postings)
    if type(postings) ~= 'table' or not Foundation.jsonContainerKind(postings) then
        return failure('VALIDATION_FAILED', 'postings must be a bounded array.')
    end
    local normalized, seen, total = {}, {}, 0
    for index, posting in ipairs(postings) do
        if index > 16 or type(posting) ~= 'table' or not Foundation.jsonContainerKind(posting) then
            return failure('VALIDATION_FAILED', 'postings must contain between two and sixteen entries.')
        end
        local fields = 0
        for key in pairs(posting) do
            if key ~= 'account_id' and key ~= 'amount_minor' and key ~= 'metadata_json' then
                return failure('VALIDATION_FAILED', 'A posting contains an unknown property.')
            end
            fields = fields + 1
        end
        if fields < 2 or not Foundation.isUuid(posting.account_id)
            or type(posting.amount_minor) ~= 'number' or math.type(posting.amount_minor) ~= 'integer'
            or posting.amount_minor == 0 or posting.amount_minor < -MAX_MINOR
            or posting.amount_minor > MAX_MINOR or seen[posting.account_id] then
            return failure('VALIDATION_FAILED', 'Posting accounts must be unique UUIDs with non-zero safe integer amounts.')
        end
        seen[posting.account_id] = true
        total = total + posting.amount_minor
        normalized[#normalized + 1] = {
            accountId = posting.account_id,
            amountMinor = posting.amount_minor,
            metadataJson = posting.metadata_json or '{}',
            sequence = index,
        }
    end
    for key in pairs(postings) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 or key > #normalized then
            return failure('VALIDATION_FAILED', 'postings must be a contiguous array.')
        end
    end
    if #normalized < 2 or #normalized > 16 then
        return failure('VALIDATION_FAILED', 'postings must contain between two and sixteen entries.')
    end
    if total ~= 0 then
        return failure('LEDGER_UNBALANCED', 'The signed posting sum must equal zero.')
    end
    return normalized, nil
end

function Domain.invertPostings(postings)
    local inverted = {}
    for index, posting in ipairs(postings or {}) do
        inverted[index] = {
            accountId = posting.accountId,
            amountMinor = -posting.amountMinor,
            metadataJson = posting.metadataJson or '{}',
            sequence = index,
        }
    end
    return inverted
end

function Domain.validateRefund(originalEntries, refundEntries, anchorAccountId,
    refundAmount, cumulativeByAccount)
    if type(refundAmount) ~= 'number' or math.type(refundAmount) ~= 'integer'
        or refundAmount < 1 or refundAmount > MAX_MINOR then
        return failure('VALIDATION_FAILED', 'refund amount must be a positive safe integer.')
    end
    local original, refund = {}, {}
    for _, entry in ipairs(originalEntries or {}) do
        original[entry.accountId] = entry.amountMinor
    end
    for _, entry in ipairs(refundEntries or {}) do
        local source = original[entry.accountId]
        if source == nil or entry.amountMinor * source >= 0 then
            return failure('REFUND_POSTING_INVALID', 'Refund postings must invert original transaction accounts.')
        end
        refund[entry.accountId] = entry.amountMinor
        local consumed = tonumber(cumulativeByAccount and cumulativeByAccount[entry.accountId]) or 0
        if math.abs(entry.amountMinor) + consumed > math.abs(source) then
            return failure('REFUND_LIMIT_EXCEEDED', 'The refund exceeds an original posting amount.')
        end
    end
    if not Foundation.isUuid(anchorAccountId) or refund[anchorAccountId] ~= refundAmount then
        return failure('REFUND_ANCHOR_INVALID', 'The refund anchor must receive exactly refund_amount_minor.')
    end
    return true, nil
end

function Domain.holdTransition(hold, operation, amountMinor)
    if type(hold) ~= 'table' then return failure('HOLD_NOT_FOUND', 'The hold does not exist.') end
    local state = hold.state
    local remaining = tonumber(hold.remaining_minor or hold.remainingMinor)
    local version = tonumber(hold.version)
    if not remaining or not version then
        return failure('DATABASE_RESULT_INVALID', 'The hold state is invalid.')
    end
    if state == 'expired' or state == 'released' or state == 'captured' then
        return failure('HOLD_NOT_ACTIVE', 'The hold is no longer active.')
    end
    if operation == 'release' then
        return { state = 'released', capturedMinor = 0, releasedMinor = remaining,
            remainingMinor = 0, nextVersion = version + 1 }, nil
    end
    if type(amountMinor) ~= 'number' or math.type(amountMinor) ~= 'integer'
        or amountMinor < 1 or amountMinor > remaining then
        return failure('HOLD_CAPTURE_EXCEEDS_REMAINING', 'The capture exceeds the remaining hold amount.')
    end
    if hold.capture_policy == 'single' and amountMinor ~= remaining then
        return failure('PARTIAL_CAPTURE_NOT_ALLOWED', 'This hold only permits a single full capture.')
    end
    local nextRemaining = remaining - amountMinor
    return {
        state = nextRemaining == 0 and 'captured' or 'partially_captured',
        capturedMinor = amountMinor,
        releasedMinor = 0,
        remainingMinor = nextRemaining,
        nextVersion = version + 1,
    }, nil
end

return Domain
end
