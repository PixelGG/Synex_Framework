return function(service, runtime)
    local Foundation = runtime.Foundation
    local Domain = runtime.Domain
    local domainError = runtime.domainError
    local db = runtime.db
    local shape = runtime.shape
    local uuid = runtime.uuid
    local currency = runtime.currency
    local utf8 = runtime.utf8
    local mutationBase = runtime.mutationBase
    local readBase = runtime.readBase
    local mergeFields = runtime.mergeFields
    local principalFields = runtime.principalFields
    local provenanceFields = runtime.provenanceFields

    function service.currency_register(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, currency_code = true, display_name = true, minor_unit = true,
        }), { 'idempotency_key', 'currency_code', 'display_name', 'minor_unit' })
        if not candidate then return nil, validationError end
        if not currency(candidate.currency_code) then return nil, select(2, currency(candidate.currency_code)) end
        if not utf8(candidate.display_name, 1, 64, 'display_name') then
            return nil, select(2, utf8(candidate.display_name, 1, 64, 'display_name'))
        end
        if type(candidate.minor_unit) ~= 'number' or math.type(candidate.minor_unit) ~= 'integer'
            or candidate.minor_unit < 0 or candidate.minor_unit > 6 then
            return nil, domainError('VALIDATION_FAILED', 'minor_unit must be an integer from zero through six.')
        end
        local command, commandError = mutationBase('currency_register', candidate, context)
        if not command then return nil, commandError end
        command.currencyCode, command.displayName, command.minorUnit = candidate.currency_code,
            candidate.display_name, candidate.minor_unit
        return db:registerCurrencyV2(command)
    end

    function service.register_currency(request, context)
        local response, responseError = service.currency_register(request, context)
        if not response then return nil, responseError end
        return {
            currency_id = response.currency_id,
            currency_code = response.currency_code,
            display_name = response.display_name,
            minor_unit = response.minor_unit,
            status = response.status,
        }, nil
    end

    function service.currency_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            currency = true, currency_code = true, currency_id = true,
        }), {})
        if not candidate then return nil, validationError end
        local identifier = candidate.currency or candidate.currency_code or candidate.currency_id
        local supplied = (candidate.currency ~= nil and 1 or 0)
            + (candidate.currency_code ~= nil and 1 or 0)
            + (candidate.currency_id ~= nil and 1 or 0)
        if supplied ~= 1 then
            return nil, domainError('VALIDATION_FAILED', 'Exactly one currency identifier is required.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getCurrency(identifier)
    end

    function service.currency_list(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            cursor = true, limit = true,
        }), {})
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:listCurrencies(candidate.cursor, candidate.limit)
    end

    function service.currency_update(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, currency_id = true, display_name = true,
            minor_unit = true, status = true,
        }), { 'idempotency_key', 'currency_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.currency_id) then
            return nil, domainError('VALIDATION_FAILED', 'currency_id must be a lowercase UUID.')
        end
        if candidate.display_name == nil and candidate.minor_unit == nil and candidate.status == nil then
            return nil, domainError('VALIDATION_FAILED', 'At least one currency property must change.')
        end
        if candidate.display_name ~= nil and not utf8(candidate.display_name, 1, 64, 'display_name') then
            return nil, select(2, utf8(candidate.display_name, 1, 64, 'display_name'))
        end
        if candidate.minor_unit ~= nil and (type(candidate.minor_unit) ~= 'number'
            or math.type(candidate.minor_unit) ~= 'integer' or candidate.minor_unit < 0
            or candidate.minor_unit > 6) then
            return nil, domainError('VALIDATION_FAILED', 'minor_unit must be an integer from zero through six.')
        end
        if candidate.status ~= nil and candidate.status ~= 'active' and candidate.status ~= 'disabled' then
            return nil, domainError('VALIDATION_FAILED', 'Currency status must be active or disabled.')
        end
        local command, commandError = mutationBase('currency_update', candidate, context)
        if not command then return nil, commandError end
        command.currencyId, command.displayName, command.minorUnit, command.status = candidate.currency_id,
            candidate.display_name, candidate.minor_unit, candidate.status
        return db:updateCurrency(command)
    end

    function service.create(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, currency_code = true, account_role = true,
            account_key = true, owner_kind = true, owner_ref = true, actor_ref = true,
        }), { 'idempotency_key', 'currency_code', 'account_role', 'owner_kind', 'owner_ref' })
        if not candidate then return nil, validationError end
        if not currency(candidate.currency_code) then return nil, select(2, currency(candidate.currency_code)) end
        if candidate.account_role ~= 'asset' and candidate.account_role ~= 'mint'
            and candidate.account_role ~= 'burn' then
            return nil, domainError('VALIDATION_FAILED', 'account_role must be asset, mint, or burn.')
        end
        if candidate.owner_kind ~= 'system' and candidate.owner_kind ~= 'user'
            and candidate.owner_kind ~= 'character' and candidate.owner_kind ~= 'group' then
            return nil, domainError('VALIDATION_FAILED', 'owner_kind is invalid.')
        end
        local ownerValid = candidate.owner_kind == 'group' and Foundation.isPublicId(candidate.owner_ref)
            or candidate.owner_kind == 'system' and Domain.validResourceName(candidate.owner_ref)
            or (candidate.owner_kind == 'user' or candidate.owner_kind == 'character')
                and Foundation.isSubjectId(candidate.owner_ref)
        if not ownerValid then return nil, domainError('VALIDATION_FAILED', 'owner_ref is invalid.') end
        if candidate.account_role ~= 'asset'
            and (candidate.owner_kind ~= 'system'
                or type(context) ~= 'table' or candidate.owner_ref ~= context.caller) then
            return nil, domainError('VALIDATION_FAILED',
                'Canonical currency system accounts must be owned by the authoritative caller.')
        end
        if candidate.account_key ~= nil and (type(candidate.account_key) ~= 'string'
            or #candidate.account_key < 2 or #candidate.account_key > 64
            or candidate.account_key:match('^[a-z][a-z0-9_.:-]*$') == nil) then
            return nil, domainError('VALIDATION_FAILED', 'account_key is invalid.')
        end
        local command, commandError = mutationBase('account_create', candidate, context)
        if not command then return nil, commandError end
        command.currencyCode, command.accountRole, command.accountKey = candidate.currency_code,
            candidate.account_role, candidate.account_key
        command.ownerKind, command.ownerRef = candidate.owner_kind, candidate.owner_ref
        return db:createAccountV2(command)
    end

    function service.get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { account_id = true }), { 'account_id' })
        if not candidate then return nil, validationError end
        local _, idError = uuid(candidate.account_id, 'account_id')
        if idError then return nil, idError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getAccount(candidate.account_id, accountAuthority, 'balance.read')
    end

    service.get_snapshot = service.get

    function service.list_by_owner(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            owner_kind = true, owner_ref = true, cursor = true, limit = true,
        }), { 'owner_kind', 'owner_ref' })
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:listOwnerAccountsV2(candidate.owner_kind, candidate.owner_ref,
            accountAuthority, candidate.cursor, candidate.limit)
    end

    service.list_owner_accounts = service.list_by_owner

    local function accountStatus(request, context, operation, method)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, expected_version = true,
        }), { 'idempotency_key', 'account_id', 'expected_version' })
        if not candidate then return nil, validationError end
        local _, idError = uuid(candidate.account_id, 'account_id')
        if idError then return nil, idError end
        if type(candidate.expected_version) ~= 'number' or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 then
            return nil, domainError('VALIDATION_FAILED', 'expected_version must be a positive integer.')
        end
        local command, commandError = mutationBase(operation, candidate, context)
        if not command then return nil, commandError end
        command.accountId, command.expectedVersion = candidate.account_id, candidate.expected_version
        return method(db, command)
    end

    function service.freeze(request, context)
        return accountStatus(request, context, 'account_freeze', db.freezeAccount)
    end
    function service.unfreeze(request, context)
        return accountStatus(request, context, 'account_unfreeze', db.unfreezeAccount)
    end
    function service.close(request, context)
        return accountStatus(request, context, 'account_close', db.closeAccount)
    end

    function service.balance_get(request, context) return service.get(request, context) end

    function service.balance_get_at(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            account_id = true, at = true,
        }), { 'account_id', 'at' })
        if not candidate then return nil, validationError end
        local _, idError = uuid(candidate.account_id, 'account_id')
        if idError then return nil, idError end
        if type(candidate.at) ~= 'string' or #candidate.at < 20 or #candidate.at > 32 then
            return nil, domainError('VALIDATION_FAILED', 'at must be a bounded ISO-8601 timestamp.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getBalanceAt(candidate.account_id, candidate.at, accountAuthority)
    end
end
