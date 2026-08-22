return function(Foundation)
local MAX_MINOR = Foundation.MAX_MINOR
local ACCOUNT_ACCESS_PERMISSIONS = Foundation.ACCOUNT_ACCESS_PERMISSIONS
local domainError = Foundation.domainError
local isUuid = Foundation.isUuid
local isSubjectId = Foundation.isSubjectId
local characterLength = Foundation.characterLength
local validateShape = Foundation.validateShape
local createCanonicalEncoder = Foundation.createCanonicalEncoder
local reportUnexpectedError = Foundation.reportUnexpectedError

local function createService(deps)
    local db = assert(deps.db, 'synex_accounts service requires deps.db')
    local jsonDecode = assert(deps.jsonDecode, 'synex_accounts service requires deps.jsonDecode')
    local canonicalEncode = createCanonicalEncoder(assert(deps.jsonEncode, 'synex_accounts service requires deps.jsonEncode'))
    local errorSink = assert(type(deps.errorSink) == 'function' and deps.errorSink,
        'synex_accounts service requires deps.errorSink')

    local function metadataJson(value)
        if value == nil then return '{}' end
        if type(value) ~= 'string' or #value > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must be a JSON object no larger than 4096 bytes.')
        end
        local ok, decoded = pcall(jsonDecode, value)
        if not ok or type(decoded) ~= 'table' then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must contain a JSON object.')
        end
        local encodedOk, encoded = pcall(canonicalEncode, decoded)
        if not encodedOk or #encoded > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json exceeds the supported shape or size.')
        end
        return encoded, nil
    end

    local function validateIdempotencyKey(value)
        if not isUuid(value) then return nil, domainError('VALIDATION_FAILED', 'idempotency_key must be a lowercase UUID.') end
        return true, nil
    end

    local function validateAmount(value)
        if type(value) ~= 'number' or math.type(value) ~= 'integer' or value < 1 or value > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED', 'amount_minor must be a positive safe integer.')
        end
        return true, nil
    end

    local function validateReference(value)
        if value ~= nil and (characterLength(value) < 1 or characterLength(value) > 128) then
            return nil, domainError('VALIDATION_FAILED', 'reference must contain 1-128 valid UTF-8 characters when supplied.')
        end
        return true, nil
    end

    local function validateActor(value)
        if value ~= nil and (type(value) ~= 'string' or #value > 128 or not value:match('^[A-Za-z0-9:._%-]+$')) then
            return nil, domainError('VALIDATION_FAILED', 'actor_ref contains unsupported characters or is too long.')
        end
        return true, nil
    end

    local function validatePrincipal(kind, value)
        if kind ~= 'system' and kind ~= 'resource' and kind ~= 'user' and kind ~= 'character' and kind ~= 'group' then
            return nil, domainError('VALIDATION_FAILED', 'principal_kind is invalid.')
        end
        if kind == 'system' or kind == 'resource' then
            if type(value) ~= 'string' or #value < 2 or #value > 64 or not value:match('^[a-z][a-z0-9_]+$') then
                return nil, domainError('VALIDATION_FAILED', 'Resource principal_ref must be a bounded lowercase resource name.')
            end
        elseif kind == 'group' and not isUuid(value) then
            return nil, domainError('VALIDATION_FAILED', 'Group principal_ref must be a lowercase UUID.')
        elseif kind ~= 'group' and not isSubjectId(value) then
            return nil, domainError('VALIDATION_FAILED', 'User and character principal_ref must be a bounded opaque identifier.')
        end
        return true, nil
    end

    local function fingerprint(name, ...)
        local values = table.pack(...)
        local parts = { name }
        for index = 1, values.n do
            local value = values[index]
            local normalized = value == nil and '<nil>' or tostring(value)
            parts[#parts + 1] = tostring(#normalized) .. ':' .. normalized
        end
        return table.concat(parts, '|')
    end

    local service = {}

    function service.register_currency(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, currency_code = true, display_name = true, minor_unit = true, actor_ref = true
        }, { 'idempotency_key', 'currency_code', 'display_name', 'minor_unit' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if type(request.currency_code) ~= 'string' or #request.currency_code < 2 or #request.currency_code > 16
            or not request.currency_code:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'currency_code must be 2-16 lowercase ASCII characters.')
        end
        if characterLength(request.display_name) < 1 or characterLength(request.display_name) > 64 then
            return nil, domainError('VALIDATION_FAILED', 'display_name must contain 1-64 valid UTF-8 characters.')
        end
        if type(request.minor_unit) ~= 'number' or math.type(request.minor_unit) ~= 'integer'
            or request.minor_unit < 0 or request.minor_unit > 6 then
            return nil, domainError('VALIDATION_FAILED', 'minor_unit must be an integer from 0 through 6.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, currencyCode = request.currency_code,
            displayName = request.display_name, minorUnit = request.minor_unit, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('register_currency',
            command.currencyCode, command.displayName, command.minorUnit, command.actorRef
        )
        return db:registerCurrency(command)
    end

    function service.create(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, currency_code = true, account_role = true, account_key = true,
            owner_kind = true, owner_ref = true, metadata_json = true, actor_ref = true
        }, { 'idempotency_key', 'currency_code', 'account_role', 'owner_kind', 'owner_ref' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if type(request.currency_code) ~= 'string' or #request.currency_code < 2 or #request.currency_code > 16
            or not request.currency_code:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'currency_code is invalid.')
        end
        if request.account_role ~= 'asset' and request.account_role ~= 'mint' and request.account_role ~= 'burn' then
            return nil, domainError('VALIDATION_FAILED', 'account_role must be asset, mint, or burn.')
        end
        if request.owner_kind ~= 'system' and request.owner_kind ~= 'user'
            and request.owner_kind ~= 'character' and request.owner_kind ~= 'group' then
            return nil, domainError('VALIDATION_FAILED', 'owner_kind is invalid.')
        end
        if request.owner_kind == 'system' then
            if type(request.owner_ref) ~= 'string' or #request.owner_ref < 2 or #request.owner_ref > 64
                or not request.owner_ref:match('^[a-z][a-z0-9_%.%-]+$') then
                return nil, domainError('VALIDATION_FAILED', 'System owner_ref must be a bounded lowercase key.')
            end
        elseif request.owner_kind == 'group' and not isUuid(request.owner_ref) then
            return nil, domainError('VALIDATION_FAILED', 'Group owner_ref must be a lowercase UUID.')
        elseif request.owner_kind ~= 'group' and not isSubjectId(request.owner_ref) then
            return nil, domainError('VALIDATION_FAILED', 'User and character owner_ref must be a bounded opaque identifier.')
        end
        if request.account_role ~= 'asset' and request.owner_kind ~= 'system' then
            return nil, domainError('VALIDATION_FAILED', 'Mint and burn accounts must be system-owned.')
        end
        if request.account_key ~= nil and (type(request.account_key) ~= 'string' or #request.account_key < 3
            or #request.account_key > 64 or not request.account_key:match('^[a-z][a-z0-9_]+$')) then
            return nil, domainError('VALIDATION_FAILED', 'account_key must be 3-64 lowercase ASCII characters when supplied.')
        end
        if request.account_role ~= 'asset' and request.account_key == nil then
            return nil, domainError('VALIDATION_FAILED', 'Mint and burn accounts require account_key.')
        end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, currencyCode = request.currency_code,
            accountRole = request.account_role, accountKey = request.account_key,
            ownerKind = request.owner_kind, ownerRef = request.owner_ref,
            metadataJson = metadata, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('create',
            command.currencyCode, command.accountRole, command.accountKey, command.ownerKind,
            command.ownerRef, command.metadataJson, command.actorRef
        )
        return db:createAccount(command)
    end

    function service.get_snapshot(request)
        local valid, validationError = validateShape(request, { account_id = true }, { 'account_id' })
        if not valid then return nil, validationError end
        if not isUuid(request.account_id) then return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.') end
        return db:getSnapshot(request.account_id)
    end

    function service.list_owner_accounts(request)
        local valid, validationError = validateShape(request, {
            owner_kind = true, owner_ref = true
        }, { 'owner_kind', 'owner_ref' })
        if not valid then return nil, validationError end
        if request.owner_kind ~= 'system' and request.owner_kind ~= 'user'
            and request.owner_kind ~= 'character' and request.owner_kind ~= 'group' then
            return nil, domainError('VALIDATION_FAILED', 'owner_kind is invalid.')
        end
        if request.owner_kind == 'system' then
            if type(request.owner_ref) ~= 'string' or #request.owner_ref < 2 or #request.owner_ref > 64
                or not request.owner_ref:match('^[a-z][a-z0-9_%.%-]+$') then
                return nil, domainError('VALIDATION_FAILED', 'System owner_ref is invalid.')
            end
        elseif request.owner_kind == 'group' then
            if not isUuid(request.owner_ref) then
                return nil, domainError('VALIDATION_FAILED', 'Group owner_ref must be a lowercase UUID.')
            end
        elseif not isSubjectId(request.owner_ref) then
            return nil, domainError('VALIDATION_FAILED', 'User or character owner_ref is invalid.')
        end
        return db:listOwnerAccounts(request.owner_kind, request.owner_ref)
    end

    local function ledgerCommand(request, operation, sourceKey, destinationKey)
        local allowed = {
            idempotency_key = true, amount_minor = true, reference = true,
            actor_ref = true, metadata_json = true
        }
        allowed[sourceKey] = true
        allowed[destinationKey] = true
        local valid, validationError = validateShape(request, allowed,
            { 'idempotency_key', sourceKey, destinationKey, 'amount_minor' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request[sourceKey]) or not isUuid(request[destinationKey]) then
            return nil, domainError('VALIDATION_FAILED', 'Both account identifiers must be lowercase UUIDs.')
        end
        if request[sourceKey] == request[destinationKey] then
            return nil, domainError('VALIDATION_FAILED', 'Debit and credit accounts must differ.')
        end
        valid, validationError = validateAmount(request.amount_minor)
        if not valid then return nil, validationError end
        valid, validationError = validateReference(request.reference)
        if not valid then return nil, validationError end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end
        local command = {
            idempotencyKey = request.idempotency_key, sourceAccountId = request[sourceKey],
            destinationAccountId = request[destinationKey], amountMinor = request.amount_minor,
            reference = request.reference, actorRef = request.actor_ref, metadataJson = metadata,
            kind = operation
        }
        command.fingerprint = fingerprint(operation,
            command.sourceAccountId, command.destinationAccountId, command.amountMinor,
            command.reference, command.actorRef, command.metadataJson
        )
        return command, nil
    end

    function service.transfer(request)
        local command, validationError = ledgerCommand(request, 'transfer', 'source_account_id', 'destination_account_id')
        if not command then return nil, validationError end
        return db:post(command)
    end

    function service.debit(request)
        local command, validationError = ledgerCommand(request, 'debit', 'account_id', 'counterparty_account_id')
        if not command then return nil, validationError end
        return db:post(command)
    end

    function service.credit(request)
        local command, validationError = ledgerCommand(request, 'credit', 'counterparty_account_id', 'account_id')
        if not command then return nil, validationError end
        return db:post(command)
    end

    function service.mint(request)
        local command, validationError = ledgerCommand(request, 'mint', 'mint_account_id', 'account_id')
        if not command then return nil, validationError end
        return db:post(command)
    end

    function service.burn(request)
        local command, validationError = ledgerCommand(request, 'burn', 'account_id', 'burn_account_id')
        if not command then return nil, validationError end
        return db:post(command)
    end

    function service.create_hold(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, account_id = true, capture_account_id = true, amount_minor = true,
            expires_in_seconds = true, reference = true, actor_ref = true, metadata_json = true
        }, { 'idempotency_key', 'account_id', 'capture_account_id', 'amount_minor', 'expires_in_seconds' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.account_id) or not isUuid(request.capture_account_id) or request.account_id == request.capture_account_id then
            return nil, domainError('VALIDATION_FAILED', 'Hold accounts must be distinct lowercase UUIDs.')
        end
        valid, validationError = validateAmount(request.amount_minor)
        if not valid then return nil, validationError end
        if type(request.expires_in_seconds) ~= 'number' or math.type(request.expires_in_seconds) ~= 'integer'
            or request.expires_in_seconds < 1 or request.expires_in_seconds > 604800 then
            return nil, domainError('VALIDATION_FAILED', 'expires_in_seconds must be an integer from 1 through 604800.')
        end
        valid, validationError = validateReference(request.reference)
        if not valid then return nil, validationError end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end
        local command = {
            idempotencyKey = request.idempotency_key, accountId = request.account_id,
            captureAccountId = request.capture_account_id, amountMinor = request.amount_minor,
            expiresInSeconds = request.expires_in_seconds, reference = request.reference,
            actorRef = request.actor_ref, metadataJson = metadata
        }
        command.fingerprint = fingerprint('create_hold',
            command.accountId, command.captureAccountId, command.amountMinor, command.expiresInSeconds,
            command.reference, command.actorRef, command.metadataJson
        )
        return db:createHold(command)
    end

    function service.get_hold(request)
        local valid, validationError = validateShape(request, { hold_id = true }, { 'hold_id' })
        if not valid then return nil, validationError end
        if not isUuid(request.hold_id) then return nil, domainError('VALIDATION_FAILED', 'hold_id must be a lowercase UUID.') end
        return db:getHold(request.hold_id)
    end

    local function holdTransitionCommand(request, operation)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, hold_id = true, reference = true, actor_ref = true, metadata_json = true
        }, { 'idempotency_key', 'hold_id' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.hold_id) then return nil, domainError('VALIDATION_FAILED', 'hold_id must be a lowercase UUID.') end
        valid, validationError = validateReference(request.reference)
        if not valid then return nil, validationError end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end
        local command = {
            idempotencyKey = request.idempotency_key, holdId = request.hold_id,
            reference = request.reference, actorRef = request.actor_ref, metadataJson = metadata
        }
        command.fingerprint = fingerprint(operation,
            command.holdId, command.reference, command.actorRef, command.metadataJson
        )
        return command, nil
    end

    function service.capture_hold(request)
        local command, validationError = holdTransitionCommand(request, 'capture_hold')
        if not command then return nil, validationError end
        return db:captureHold(command)
    end

    function service.release_hold(request)
        local command, validationError = holdTransitionCommand(request, 'release_hold')
        if not command then return nil, validationError end
        return db:releaseHold(command)
    end

    function service.reverse(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, transaction_id = true, reason = true, actor_ref = true, metadata_json = true
        }, { 'idempotency_key', 'transaction_id', 'reason' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.transaction_id) then
            return nil, domainError('VALIDATION_FAILED', 'transaction_id must be a lowercase UUID.')
        end
        if characterLength(request.reason) < 1 or characterLength(request.reason) > 256 then
            return nil, domainError('VALIDATION_FAILED', 'reason must contain 1-256 valid UTF-8 characters.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end
        local command = {
            idempotencyKey = request.idempotency_key, transactionId = request.transaction_id,
            reason = request.reason, actorRef = request.actor_ref, metadataJson = metadata
        }
        command.fingerprint = fingerprint('reverse', command.transactionId, command.reason,
            command.actorRef, command.metadataJson)
        return db:reverse(command)
    end

    function service.create_access_role(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, account_id = true, role_key = true, display_name = true,
            permissions = true, actor_ref = true
        }, { 'idempotency_key', 'account_id', 'role_key', 'display_name', 'permissions' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.account_id) then return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.') end
        if type(request.role_key) ~= 'string' or #request.role_key < 2 or #request.role_key > 48
            or not request.role_key:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'role_key must be 2-48 lowercase ASCII characters.')
        end
        if characterLength(request.display_name) < 1 or characterLength(request.display_name) > 96 then
            return nil, domainError('VALIDATION_FAILED', 'display_name must contain 1-96 valid UTF-8 characters.')
        end
        if type(request.permissions) ~= 'table' then
            return nil, domainError('VALIDATION_FAILED', 'permissions must be a non-empty array.')
        end
        local permissions, seen = {}, {}
        for index, permission in ipairs(request.permissions) do
            if index > 7 or not ACCOUNT_ACCESS_PERMISSIONS[permission] or seen[permission] then
                return nil, domainError('VALIDATION_FAILED', 'permissions contains an invalid or duplicate entry.')
            end
            seen[permission] = true
            permissions[#permissions + 1] = permission
        end
        for key in pairs(request.permissions) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 or key > #permissions then
                return nil, domainError('VALIDATION_FAILED', 'permissions must be a contiguous array.')
            end
        end
        if #permissions == 0 then return nil, domainError('VALIDATION_FAILED', 'permissions must not be empty.') end
        table.sort(permissions)
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, accountId = request.account_id,
            roleKey = request.role_key, displayName = request.display_name,
            permissions = permissions, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('create_access_role', command.accountId, command.roleKey,
            command.displayName, table.concat(command.permissions, ','), command.actorRef)
        return db:createAccessRole(command)
    end

    function service.grant_access(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, account_id = true, role_id = true, principal_kind = true,
            principal_ref = true, valid_for_seconds = true, actor_ref = true
        }, { 'idempotency_key', 'account_id', 'role_id', 'principal_kind', 'principal_ref' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.account_id) or not isUuid(request.role_id) then
            return nil, domainError('VALIDATION_FAILED', 'account_id and role_id must be lowercase UUIDs.')
        end
        valid, validationError = validatePrincipal(request.principal_kind, request.principal_ref)
        if not valid then return nil, validationError end
        if request.valid_for_seconds ~= nil and (type(request.valid_for_seconds) ~= 'number'
            or math.type(request.valid_for_seconds) ~= 'integer' or request.valid_for_seconds < 1
            or request.valid_for_seconds > 31536000) then
            return nil, domainError('VALIDATION_FAILED', 'valid_for_seconds must be an integer from 1 through 31536000.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, accountId = request.account_id, roleId = request.role_id,
            principalKind = request.principal_kind, principalRef = request.principal_ref,
            validForSeconds = request.valid_for_seconds, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('grant_access', command.accountId, command.roleId,
            command.principalKind, command.principalRef, command.validForSeconds, command.actorRef)
        return db:grantAccess(command)
    end

    function service.revoke_access(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, grant_id = true, reason = true, actor_ref = true
        }, { 'idempotency_key', 'grant_id', 'reason', 'actor_ref' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.grant_id) then return nil, domainError('VALIDATION_FAILED', 'grant_id must be a lowercase UUID.') end
        if characterLength(request.reason) < 1 or characterLength(request.reason) > 256 then
            return nil, domainError('VALIDATION_FAILED', 'reason must contain 1-256 valid UTF-8 characters.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, grantId = request.grant_id,
            reason = request.reason, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('revoke_access', command.grantId, command.reason, command.actorRef)
        return db:revokeAccess(command)
    end

    function service.get_access(request)
        local valid, validationError = validateShape(request, {
            account_id = true, principal_kind = true, principal_ref = true
        }, { 'account_id', 'principal_kind', 'principal_ref' })
        if not valid then return nil, validationError end
        if not isUuid(request.account_id) then return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.') end
        valid, validationError = validatePrincipal(request.principal_kind, request.principal_ref)
        if not valid then return nil, validationError end
        return db:getAccess(request.account_id, request.principal_kind, request.principal_ref)
    end

    function service.run_reconciliation(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, currency_code = true, actor_ref = true
        }, { 'idempotency_key', 'currency_code' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if type(request.currency_code) ~= 'string' or #request.currency_code < 2 or #request.currency_code > 16
            or not request.currency_code:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'currency_code is invalid.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, currencyCode = request.currency_code, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('run_reconciliation', command.currencyCode, command.actorRef)
        return db:runReconciliation(command)
    end

    function service.get_integrity(request)
        local valid, validationError = validateShape(request, { currency_code = true }, { 'currency_code' })
        if not valid then return nil, validationError end
        if type(request.currency_code) ~= 'string' or #request.currency_code < 2 or #request.currency_code > 16
            or not request.currency_code:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'currency_code is invalid.')
        end
        return db:getIntegrity(request.currency_code)
    end

    function service.get_control_summary(request)
        local valid, validationError = validateShape(request, {}, {})
        if not valid then return nil, validationError end
        return db:getControlSummary()
    end

    local guarded = {}
    for name, handler in pairs(service) do
        local currentHandler, operationName = handler, name
        guarded[name] = function(request, context)
            local ok, value, handlerError = pcall(currentHandler, request, context)
            if not ok then
                reportUnexpectedError(errorSink, 'synex_accounts', operationName, context)
                return nil, domainError('DATABASE_ERROR', 'The account operation could not be completed.', true)
            end
            return value, handlerError
        end
    end
    return guarded
end

return createService
end
