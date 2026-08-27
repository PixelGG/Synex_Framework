return function(Foundation)
local function createGroupCreationApprovals(deps)
    local repository = assert(type(deps.repository) == 'table'
        and Foundation.isCallable(deps.repository.read)
        and Foundation.isCallable(deps.repository.execute)
        and deps.repository, 'group creation approvals require repository')
    local permissions = assert(type(deps.permissions) == 'table'
        and Foundation.isCallable(deps.permissions.check)
        and deps.permissions, 'group creation approvals require permissions')
    local hooks = assert(type(deps.hooks) == 'table'
        and Foundation.isCallable(deps.hooks.run)
        and deps.hooks, 'group creation approvals require hooks')
    local contextFactory = assert(Foundation.isCallable(deps.context)
        and deps.context, 'group creation approvals require context factory')
    local jsonEncode = assert(Foundation.isCallable(deps.jsonEncode)
        and deps.jsonEncode, 'group creation approvals require JSON encoder')
    local errorSink = assert(Foundation.isCallable(deps.errorSink)
        and deps.errorSink, 'group creation approvals require error sink')
    local onCommittedEffects = deps.onCommittedEffects
    if onCommittedEffects ~= nil and not Foundation.isCallable(onCommittedEffects) then
        error('group creation approvals require a callable committed-effect handler')
    end
    local canonical = Foundation.createCanonicalEncoder(jsonEncode)

    local function normalize(value, err)
        if value == false and type(err) == 'table' then return nil, err end
        return value, err
    end

    local function operationContext(traceId)
        local built, contextError = contextFactory(traceId)
        if type(built) ~= 'table' then
            return nil, contextError or Foundation.domainError('CORE_UNAVAILABLE',
                'The organization creation runtime context is unavailable.', true)
        end
        return built, nil
    end

    local function report(operation, traceId, operationError)
        pcall(errorSink, {
            operation = operation,
            traceId = traceId or 'group_creation_reconcile',
            code = type(operationError) == 'table'
                and operationError.code or 'GROUP_CREATION_RECONCILE_FAILED'
        })
    end

    local function applyCommittedEffects(effects, traceId)
        if onCommittedEffects == nil or type(effects) ~= 'table' or #effects == 0 then
            return true
        end
        local called, applied, applyError = pcall(onCommittedEffects, effects, traceId)
        if called and applied == true then return true end
        report('group_creation_committed_effects', traceId,
            type(applyError) == 'table' and applyError
                or Foundation.domainError('RUNTIME_INDEX_REFRESH_FAILED',
                    'Committed organization creation effects could not be applied.', true))
        return false
    end

    local function checkPermission(characterId, permission)
        local called, allowed, permissionError = pcall(
            permissions.check, characterId, permission)
        if called then allowed, permissionError = normalize(allowed, permissionError) end
        if called and allowed == true then return true, nil end
        return nil, type(permissionError) == 'table' and permissionError
            or Foundation.domainError('CREATION_PERMISSION_REVOKED',
                'A required organization creation permission is not currently granted.', true, {
                    character_id = characterId,
                    permission = permission
                })
    end

    local coordinator = {}

    function coordinator:advance(requestId, traceId)
        if not Foundation.isPublicId(requestId) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The organization creation request identity is invalid.')
        end
        local context, contextError = operationContext(traceId)
        if not context then return nil, contextError end
        local execution, executionError = repository:read(
            'creation_requests_execution_context',
            { creation_request_id = requestId }, context)
        if not execution then return nil, executionError end
        local creatorAllowed, creatorError = checkPermission(
            execution.requestedByCharacterId, execution.creatorPermission)
        if not creatorAllowed then return nil, creatorError end
        if type(execution.approverCharacterIds) ~= 'table'
            or #execution.approverCharacterIds ~= execution.requiredApprovals
            or #execution.approverCharacterIds < 1 or #execution.approverCharacterIds > 32 then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The approved organization creation quorum is invalid.', true)
        end
        local seen = {}
        for _, characterId in ipairs(execution.approverCharacterIds) do
            if not Foundation.isPublicId(characterId)
                or characterId == execution.requestedByCharacterId
                or seen[characterId] then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'The approved organization creation quorum is not independent.', true)
            end
            seen[characterId] = true
            local approverAllowed, approverError = checkPermission(
                characterId, execution.approvalPermission)
            if not approverAllowed then return nil, approverError end
        end

        local canonicalBeforeOk, canonicalBefore = pcall(canonical, execution.request)
        if not canonicalBeforeOk then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The approved organization creation payload is invalid.', true)
        end
        local hookCalled, hooked, hookError = pcall(hooks.run,
            'synex.groups.before_group_create',
            execution.request,
            {
                traceId = context.traceId,
                metadata = {
                    caller = 'synex_groups',
                    operation = 'creation_requests_execute',
                    creation_request_id = requestId
                }
            })
        if hookCalled then hooked, hookError = normalize(hooked, hookError) end
        if not hookCalled or hooked == nil then
            return nil, type(hookError) == 'table' and hookError
                or Foundation.domainError('HOOK_REJECTED',
                    'The organization creation execution hook rejected the request.')
        end
        local copiedOk, copied = pcall(Foundation.copyPlain, hooked, {
            maximumDepth = 8,
            maximumKeys = 64,
            maximumStringBytes = 4096,
            preserveContainerKind = false
        })
        local canonicalAfterOk, canonicalAfter = false, nil
        if copiedOk then canonicalAfterOk, canonicalAfter = pcall(canonical, copied) end
        if not copiedOk or not canonicalAfterOk or canonicalAfter ~= canonicalBefore then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'The organization creation execution hook cannot alter approved content.')
        end

        local created, creationError, effects = repository:execute(
            'creation_requests_execute', {
                idempotency_key = 'creation-exec:' .. requestId,
                creation_request_id = requestId,
                expected_version = execution.version,
                permissions_revalidated = true
            }, context)
        if not created then return nil, creationError end
        applyCommittedEffects(effects, context.traceId)
        return created, nil
    end

    function coordinator:expire(requestId, traceId)
        if not Foundation.isPublicId(requestId) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The organization creation request identity is invalid.')
        end
        local context, contextError = operationContext(traceId)
        if not context then return nil, contextError end
        local expired, expiryError, effects = repository:execute('creation_requests_expire', {
            idempotency_key = 'creation-expire:' .. requestId,
            creation_request_id = requestId
        }, context)
        if not expired then return nil, expiryError end
        applyCommittedEffects(effects, context.traceId)
        return expired, nil
    end

    function coordinator:reconcile(maximum)
        maximum = tonumber(maximum)
        if not maximum or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 32 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The organization creation reconciliation limit is invalid.')
        end
        local context, contextError = operationContext('group_creation_reconcile')
        if not context then return nil, contextError end
        local items, listError = repository:read(
            'creation_requests_reconcile', { maximum = maximum }, context)
        if not items then return nil, listError end
        local reportValue = { examined = #items, executed = 0, expired = 0, failed = 0 }
        for _, item in ipairs(items) do
            local value, operationError
            if item.action == 'expire' then
                value, operationError = self:expire(
                    item.creationRequestId, 'group_creation_expire')
                if value then reportValue.expired = reportValue.expired + 1 end
            else
                value, operationError = self:advance(
                    item.creationRequestId, 'group_creation_execute')
                if value then reportValue.executed = reportValue.executed + 1 end
            end
            if not value then
                reportValue.failed = reportValue.failed + 1
                report('group_creation_reconcile', context.traceId, operationError)
            end
        end
        return reportValue, nil
    end

    return coordinator
end

return createGroupCreationApprovals
end
