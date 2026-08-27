return function(service, runtime)
    local Foundation = runtime.Foundation
    local Domain = runtime.Domain
    local MAX_MINOR = runtime.MAX_MINOR
    local domainError = runtime.domainError
    local db = runtime.db
    local shape = runtime.shape
    local optionalSafeInteger = runtime.optionalSafeInteger
    local utf8 = runtime.utf8
    local mutationBase = runtime.mutationBase
    local readBase = runtime.readBase
    local mergeFields = runtime.mergeFields
    local principalFields = runtime.principalFields
    local provenanceFields = runtime.provenanceFields
    local checkResourceCapability = runtime.checkResourceCapability
    local rolePattern = runtime.rolePattern
    local operationKeys = runtime.operationKeys

    local operationCapabilities = {
        ['balance.read'] = 'synex.accounts.read',
        ['history.read'] = 'synex.accounts.read',
        deposit = 'synex.accounts.transfer',
        withdraw = 'synex.accounts.transfer',
        transfer = 'synex.accounts.transfer',
        post = 'synex.accounts.post',
        mint = 'synex.accounts.mint',
        burn = 'synex.accounts.burn',
        reversal = 'synex.accounts.reverse',
        refund = 'synex.accounts.refund',
        ['hold.create'] = 'synex.accounts.hold',
        ['hold.capture'] = 'synex.accounts.hold',
        ['hold.release'] = 'synex.accounts.hold',
        ['access.read'] = 'synex.accounts.access.read',
        ['access.manage'] = 'synex.accounts.access.manage',
        ['settings.manage'] = 'synex.accounts.configure',
        close = 'synex.accounts.configure',
    }
    local operationPermissions = {
        ['balance.read'] = 'balance.read',
        ['history.read'] = 'history.read',
        deposit = 'deposit', withdraw = 'withdraw', transfer = 'transfer',
        post = 'transfer', mint = 'deposit', burn = 'withdraw',
        reversal = 'transfer', refund = 'transfer',
        ['hold.create'] = 'hold.create', ['hold.capture'] = 'hold.capture',
        ['hold.release'] = 'hold.release', ['access.read'] = 'access.read',
        ['access.manage'] = 'access.manage', ['settings.manage'] = 'settings.manage',
        close = 'close',
    }
    local financialOperations = {
        post = true, deposit = true, withdraw = true, transfer = true,
        mint = true, burn = true, reversal = true, refund = true,
        ['hold.create'] = true, ['hold.capture'] = true,
    }
    local policyPreflightOperations = {
        post = true, deposit = true, withdraw = true, transfer = true,
        mint = true, burn = true, reversal = true, refund = true,
        ['hold.create'] = true, ['hold.capture'] = true, ['hold.release'] = true,
    }
    local defaultDirection = {
        deposit = 'incoming', mint = 'incoming',
        withdraw = 'outgoing', transfer = 'outgoing', burn = 'outgoing',
        ['hold.create'] = 'outgoing', ['hold.capture'] = 'outgoing',
    }

    local function permissions(value)
        if type(value) ~= 'table' or not Foundation.jsonContainerKind(value) then
            return nil, domainError('VALIDATION_FAILED', 'permissions must be a bounded array.')
        end
        local result, seen = {}, {}
        for index, permission in ipairs(value) do
            permission = Domain.permissionAliases[permission] or permission
            if index > 16 or not Domain.permissions[permission] or seen[permission] then
                return nil, domainError('VALIDATION_FAILED', 'permissions contains an invalid or duplicate value.')
            end
            seen[permission], result[#result + 1] = true, permission
        end
        if #result < 1 then return nil, domainError('VALIDATION_FAILED', 'permissions cannot be empty.') end
        table.sort(result)
        return result, nil
    end

    local function roleCreate(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, role_key = true,
            display_name = true, permissions = true, actor_ref = true,
        }), { 'idempotency_key', 'account_id', 'role_key', 'display_name', 'permissions' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id) then
            return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.')
        end
        if type(candidate.role_key) ~= 'string' or #candidate.role_key < 2
            or #candidate.role_key > 48 or candidate.role_key:match(rolePattern) == nil then
            return nil, domainError('VALIDATION_FAILED', 'role_key is invalid.')
        end
        local _, displayNameError = utf8(candidate.display_name, 1, 64, 'display_name')
        if displayNameError then return nil, displayNameError end
        local normalized, permissionsError = permissions(candidate.permissions)
        if not normalized then return nil, permissionsError end
        local command, commandError = mutationBase('access_role_create', candidate, context)
        if not command then return nil, commandError end
        command.accountId, command.roleKey, command.displayName, command.permissions = candidate.account_id,
            candidate.role_key, candidate.display_name, normalized
        return db:createAccessRoleV2(command)
    end
    service.access_role_create = roleCreate
    service.create_access_role = roleCreate

    local function accessGrant(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, role_id = true,
            target_principal_kind = true, target_principal_ref = true,
            principal_kind = true, principal_ref = true,
            valid_from_seconds = true, valid_for_seconds = true, actor_ref = true,
        }), { 'idempotency_key', 'account_id', 'role_id' })
        if not candidate then return nil, validationError end
        candidate.target_principal_kind = candidate.target_principal_kind or candidate.principal_kind
        candidate.target_principal_ref = candidate.target_principal_ref or candidate.principal_ref
        if not Foundation.isUuid(candidate.account_id) or not Foundation.isUuid(candidate.role_id)
            or not Domain.validPrincipal(candidate.target_principal_kind, candidate.target_principal_ref) then
            return nil, domainError('VALIDATION_FAILED', 'The access grant target is invalid.')
        end
        if candidate.valid_from_seconds ~= nil and (type(candidate.valid_from_seconds) ~= 'number'
            or math.type(candidate.valid_from_seconds) ~= 'integer'
            or candidate.valid_from_seconds < 0 or candidate.valid_from_seconds > 31536000) then
            return nil, domainError('VALIDATION_FAILED', 'valid_from_seconds is invalid.')
        end
        if candidate.valid_for_seconds ~= nil and (type(candidate.valid_for_seconds) ~= 'number'
            or math.type(candidate.valid_for_seconds) ~= 'integer'
            or candidate.valid_for_seconds < 1 or candidate.valid_for_seconds > 31536000) then
            return nil, domainError('VALIDATION_FAILED', 'valid_for_seconds is invalid.')
        end
        if (candidate.valid_from_seconds or 0) + (candidate.valid_for_seconds or 0) > 31536000 then
            return nil, domainError('VALIDATION_FAILED', 'The access grant validity window is too large.')
        end
        local command, commandError = mutationBase('access_grant', candidate, context)
        if not command then return nil, commandError end
        command.accountId, command.roleId = candidate.account_id, candidate.role_id
        command.principalKind, command.principalRef = candidate.target_principal_kind,
            candidate.target_principal_ref
        command.validFromSeconds, command.validForSeconds = candidate.valid_from_seconds or 0,
            candidate.valid_for_seconds
        if candidate.actor_kind == nil then return db:grantAccess(command) end
        return db:grantAccessV2(command)
    end
    service.access_grant = accessGrant
    service.grant_access = accessGrant

    local function accessRevoke(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, grant_id = true, reason = true,
            expected_version = true, actor_ref = true,
        }), { 'idempotency_key', 'grant_id', 'reason' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.grant_id) then
            return nil, domainError('VALIDATION_FAILED', 'grant_id must be a lowercase UUID.')
        end
        local _, reasonError = utf8(candidate.reason, 1, 256, 'reason')
        if reasonError then return nil, reasonError end
        if candidate.expected_version ~= nil and (type(candidate.expected_version) ~= 'number'
            or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 or candidate.expected_version > MAX_MINOR) then
            return nil, domainError('VALIDATION_FAILED', 'expected_version must be a positive safe integer.')
        end
        local command, commandError = mutationBase('access_revoke', candidate, context)
        if not command then return nil, commandError end
        command.grantId, command.reason, command.expectedVersion = candidate.grant_id,
            candidate.reason, candidate.expected_version
        return db:revokeAccessV2(command)
    end
    service.access_revoke = accessRevoke
    service.revoke_access = accessRevoke

    local function accessCheck(request, context, explain)
        local preflightFields = explain and {
            operation = true, amount_minor = true, direction = true,
        } or {}
        local candidate, validationError = shape(request, mergeFields(principalFields,
            preflightFields, {
            account_id = true, target_principal_kind = true, target_principal_ref = true,
            principal_kind = true, principal_ref = true,
        permission = true,
        }), { 'account_id', 'principal_kind', 'principal_ref', 'permission' })
        if not candidate then return nil, validationError end
        candidate.target_principal_kind = candidate.target_principal_kind or candidate.principal_kind
        candidate.target_principal_ref = candidate.target_principal_ref or candidate.principal_ref
        local normalizedPermission = Domain.permissionAliases[candidate.permission]
            or candidate.permission
        if not Foundation.isUuid(candidate.account_id)
            or not Domain.validPrincipal(candidate.target_principal_kind, candidate.target_principal_ref)
            or not Domain.permissions[normalizedPermission] then
            return nil, domainError('VALIDATION_FAILED', 'The account access check is invalid.')
        end
        local operation = candidate.operation or normalizedPermission
        if explain and (not operationCapabilities[operation]
            or operationPermissions[operation] ~= normalizedPermission) then
            return nil, domainError('VALIDATION_FAILED',
                'operation and permission do not describe the same account action.')
        end
        if explain and candidate.amount_minor ~= nil
            and (type(candidate.amount_minor) ~= 'number'
                or math.type(candidate.amount_minor) ~= 'integer'
                or candidate.amount_minor < 1 or candidate.amount_minor > MAX_MINOR) then
            return nil, domainError('VALIDATION_FAILED',
                'amount_minor must be a positive JavaScript-safe integer.')
        end
        if explain and candidate.direction ~= nil and candidate.direction ~= 'incoming'
            and candidate.direction ~= 'outgoing' then
            return nil, domainError('VALIDATION_FAILED',
                'direction must be incoming or outgoing.')
        end
        if explain and not financialOperations[operation]
            and (candidate.amount_minor ~= nil or candidate.direction ~= nil) then
            return nil, domainError('VALIDATION_FAILED',
                'Non-financial access preflights cannot include an amount or direction.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        local resourceCapability
        if explain then
            local allowed = checkResourceCapability(accountAuthority.callerResource,
                operationCapabilities[operation], 'accounts.access.explain:' .. operation)
            resourceCapability = allowed == true
        end
        local result, checkError = db:checkAccess({ accountId = candidate.account_id,
            principalKind = candidate.target_principal_kind,
            principalRef = candidate.target_principal_ref,
            permission = normalizedPermission,
            authority = accountAuthority,
            resourceCapability = resourceCapability,
            preflightRequired = explain and policyPreflightOperations[operation] == true,
            amountRequired = explain and financialOperations[operation] == true,
            operation = operation,
            amountMinor = candidate.amount_minor,
            direction = candidate.direction or defaultDirection[operation],
        })
        if not result then return nil, checkError end
        local response = {
            account_id = result.accountId,
            principal_kind = result.principalKind,
            principal_ref = result.principalRef,
            permission = result.permission,
            account_state = result.accountState,
            resource_capability = result.resourceCapability == true,
            owner = result.owner == true,
            grant_active = result.grantActive == true,
            permission_granted = result.permissionGranted == true,
            allowed = result.allowed == true,
            reason = result.reason,
            grant_id = result.grantId,
            grant_version = result.grantVersion,
            role_id = result.roleId,
            role_key = result.roleKey,
            booked_minor = result.bookedMinor,
            reserved_minor = result.reservedMinor,
            available_minor = result.availableMinor,
        }
        if not explain then
            return { account_id = candidate.account_id, permission = candidate.permission,
                principal_kind = candidate.target_principal_kind,
                principal_ref = candidate.target_principal_ref,
                account_state = response.account_state,
                resource_capability = response.resource_capability,
                owner = response.owner, grant_active = response.grant_active,
                permission_granted = response.permission_granted,
                allowed = response.allowed, reason = response.reason,
                grant_id = response.grant_id, grant_version = response.grant_version,
                role_id = response.role_id, role_key = response.role_key,
                booked_minor = response.booked_minor, reserved_minor = response.reserved_minor,
                available_minor = response.available_minor }, nil
        end
        return response, nil
    end
    function service.access_check(request, context) return accessCheck(request, context, false) end
    function service.access_explain(request, context) return accessCheck(request, context, true) end

    function service.get_access(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            account_id = true, target_principal_kind = true, target_principal_ref = true,
            principal_kind = true, principal_ref = true,
        }), { 'account_id' })
        if not candidate then return nil, validationError end
        local targetKind = candidate.target_principal_kind or candidate.principal_kind
        local targetRef = candidate.target_principal_ref or candidate.principal_ref
        if not Foundation.isUuid(candidate.account_id)
            or not Domain.validPrincipal(targetKind, targetRef) then
            return nil, domainError('VALIDATION_FAILED', 'The account access target is invalid.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getAccess(candidate.account_id, targetKind, targetRef, accountAuthority)
    end

    function service.policy_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { account_id = true }), { 'account_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id) then
            return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getPolicy(candidate.account_id, accountAuthority)
    end

    function service.policy_set(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, expected_version = true,
            minimum_balance_minor = true, maximum_balance_minor = true,
            single_transfer_limit_minor = true, daily_outgoing_limit_minor = true,
            operation_mode = true, allowed_operations = true,
        }), { 'idempotency_key', 'account_id', 'expected_version',
            'operation_mode', 'allowed_operations', 'reason_code' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id)
            or type(candidate.expected_version) ~= 'number'
            or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 or candidate.expected_version > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED', 'The account policy target or version is invalid.')
        end
        if candidate.operation_mode ~= 'all' and candidate.operation_mode ~= 'allowlist' then
            return nil, domainError('VALIDATION_FAILED', 'operation_mode must be all or allowlist.')
        end
        local allowed, seen = {}, {}
        for index, operation in ipairs(candidate.allowed_operations or {}) do
            if index > 12 or not operationKeys[operation] or seen[operation] then
                return nil, domainError('VALIDATION_FAILED', 'allowed_operations contains an invalid value.')
            end
            seen[operation], allowed[#allowed + 1] = true, operation
        end
        table.sort(allowed)
        local minimum, minimumError = optionalSafeInteger(candidate.minimum_balance_minor,
            'minimum_balance_minor', true)
        if minimumError then return nil, minimumError end
        local maximum, maximumError = optionalSafeInteger(candidate.maximum_balance_minor,
            'maximum_balance_minor', true)
        if maximumError then return nil, maximumError end
        if minimum ~= nil and maximum ~= nil and minimum > maximum then
            return nil, domainError('VALIDATION_FAILED',
                'minimum_balance_minor cannot exceed maximum_balance_minor.')
        end
        local single, singleError = optionalSafeInteger(candidate.single_transfer_limit_minor,
            'single_transfer_limit_minor', false)
        if singleError then return nil, singleError end
        local daily, dailyError = optionalSafeInteger(candidate.daily_outgoing_limit_minor,
            'daily_outgoing_limit_minor', false)
        if dailyError then return nil, dailyError end
        local command, commandError = mutationBase('policy_set', candidate, context, { reasonRequired = true })
        if not command then return nil, commandError end
        command.accountId, command.expectedVersion = candidate.account_id, candidate.expected_version
        command.minimumBalanceMinor, command.maximumBalanceMinor = minimum, maximum
        command.singleTransferLimitMinor, command.dailyOutgoingLimitMinor = single, daily
        command.operationMode, command.allowedOperations = candidate.operation_mode, allowed
        return db:setPolicy(command)
    end

    function service.restriction_create(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, account_id = true, restriction_kind = true,
            reason_text = true, valid_from_seconds = true, valid_for_seconds = true,
        }), { 'idempotency_key', 'account_id', 'restriction_kind', 'reason_code' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id)
            or candidate.restriction_kind ~= 'outgoing_blocked'
                and candidate.restriction_kind ~= 'incoming_blocked'
                and candidate.restriction_kind ~= 'all_blocked' then
            return nil, domainError('VALIDATION_FAILED', 'The account restriction is invalid.')
        end
        if candidate.valid_from_seconds ~= nil and (type(candidate.valid_from_seconds) ~= 'number'
            or math.type(candidate.valid_from_seconds) ~= 'integer'
            or candidate.valid_from_seconds < 0 or candidate.valid_from_seconds > 31536000) then
            return nil, domainError('VALIDATION_FAILED', 'valid_from_seconds is invalid.')
        end
        if candidate.valid_for_seconds ~= nil and (type(candidate.valid_for_seconds) ~= 'number'
            or math.type(candidate.valid_for_seconds) ~= 'integer'
            or candidate.valid_for_seconds < 1 or candidate.valid_for_seconds > 31536000) then
            return nil, domainError('VALIDATION_FAILED', 'valid_for_seconds is invalid.')
        end
        if (candidate.valid_from_seconds or 0) + (candidate.valid_for_seconds or 0) > 31536000 then
            return nil, domainError('VALIDATION_FAILED', 'The restriction validity window is too large.')
        end
        if candidate.reason_text ~= nil then
            local _, reasonTextError = utf8(candidate.reason_text, 1, 256, 'reason_text')
            if reasonTextError then return nil, reasonTextError end
        end
        local command, commandError = mutationBase(
            'restriction_create', candidate, context, { reasonRequired = true })
        if not command then return nil, commandError end
        command.accountId, command.restrictionKind = candidate.account_id,
            candidate.restriction_kind
        command.reasonText, command.validFromSeconds, command.validForSeconds =
            candidate.reason_text, candidate.valid_from_seconds or 0,
            candidate.valid_for_seconds
        return db:createRestriction(command)
    end

    function service.restriction_revoke(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, restriction_id = true, termination_reason = true,
            expected_version = true,
        }), { 'idempotency_key', 'restriction_id', 'termination_reason', 'reason_code' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.restriction_id) then
            return nil, domainError('VALIDATION_FAILED', 'restriction_id must be a lowercase UUID.')
        end
        local _, terminationError = utf8(candidate.termination_reason, 1, 256,
            'termination_reason')
        if terminationError then return nil, terminationError end
        if type(candidate.expected_version) ~= 'number'
            or math.type(candidate.expected_version) ~= 'integer'
            or candidate.expected_version < 1 or candidate.expected_version > MAX_MINOR then
            return nil, domainError('VALIDATION_FAILED', 'expected_version must be a positive safe integer.')
        end
        local command, commandError = mutationBase('restriction_revoke', candidate, context,
            { reasonRequired = true })
        if not command then return nil, commandError end
        command.restrictionId, command.reasonText, command.expectedVersion =
            candidate.restriction_id, candidate.termination_reason, candidate.expected_version
        return db:revokeRestriction(command)
    end

    function service.restriction_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { restriction_id = true }), { 'restriction_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.restriction_id) then
            return nil, domainError('VALIDATION_FAILED', 'restriction_id must be a lowercase UUID.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getRestriction(candidate.restriction_id, accountAuthority)
    end

    function service.restriction_list(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields, {
            account_id = true, status = true, cursor = true, limit = true,
        }), { 'account_id' })
        if not candidate then return nil, validationError end
        if not Foundation.isUuid(candidate.account_id) then
            return nil, domainError('VALIDATION_FAILED', 'account_id must be a lowercase UUID.')
        end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        if candidate.status ~= nil and candidate.status ~= 'active'
            and candidate.status ~= 'revoked' and candidate.status ~= 'expired' then
            return nil, domainError('VALIDATION_FAILED', 'Restriction status is invalid.')
        end
        return db:listRestrictions(candidate.account_id, accountAuthority,
            candidate.cursor, candidate.limit, candidate.status)
    end
end
