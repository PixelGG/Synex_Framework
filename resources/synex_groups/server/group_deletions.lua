return function(Foundation)
local function createGroupDeletions(deps)
    local repository = assert(type(deps.repository) == 'table' and deps.repository,
        'group deletions require repository')
    local core = assert(type(deps.core) == 'table'
        and Foundation.isCallable(deps.core.plan)
        and Foundation.isCallable(deps.core.get)
        and Foundation.isCallable(deps.core.process)
        and deps.core, 'group deletions require Core coordinator')
    local errorSink = assert(Foundation.isCallable(deps.errorSink) and deps.errorSink,
        'group deletions require error sink')
    local onLifecycleChanged = deps.onLifecycleChanged
    if onLifecycleChanged ~= nil and not Foundation.isCallable(onLifecycleChanged) then
        error('group deletions require a callable lifecycle invalidator')
    end

    local function normalize(value, err)
        if value == false and type(err) == 'table' then return nil, err end
        return value, err
    end

    local function report(operation, errorValue)
        pcall(errorSink, {
            operation = operation,
            traceId = 'group_deletion_reconcile',
            code = type(errorValue) == 'table'
                and errorValue.code or 'DELETION_COORDINATOR_UNAVAILABLE'
        })
    end

    local function synchronizeRuntime(result)
        if onLifecycleChanged == nil or type(result) ~= 'table'
            or (result.state ~= 'dissolving' and result.state ~= 'deleted')
            or not Foundation.isPublicId(result.group_id) then
            return
        end
        local called, synchronized, synchronizationError = pcall(
            onLifecycleChanged, result.group_id, result.state)
        if not called or synchronized == false
            or (synchronized == nil and synchronizationError ~= nil) then
            report('group_deletion_runtime_invalidation',
                called and synchronizationError or synchronized)
        end
    end

    local coordinator = {}

    function coordinator:provider()
        return {
            domain = 'group',
            name = 'domain_state',
            schemaVersion = 1,
            preflight = function(request)
                local validRequest = type(request) == 'table'
                local requestId = validRequest
                    and type(request.context) == 'table'
                    and request.context.deletionRequestId or nil
                if not validRequest or request.domain ~= 'group'
                    or not Foundation.isPublicId(request.subjectId)
                    or not Foundation.isPublicId(requestId) then
                    return nil, Foundation.domainError('INVALID_DELETION_REQUEST',
                        'The organization deletion preflight request is invalid.')
                end
                return repository:preflightGroupDeletion(request.subjectId, requestId)
            end,
            execute = function()
                return nil, Foundation.domainError('DELETION_PLAN_INVALID',
                    'The Groups retention provider must never execute destructive work.')
            end
        }
    end

    function coordinator:advance(requestId)
        local request, requestError = repository:getGroupDeletionPlanRequest(requestId)
        if not request then return nil, requestError end
        if request.state == 'blocked' or request.state == 'failed'
            or request.state == 'deleted' then
            local existing, existingError = repository:getGroupDeletion(requestId)
            if existing then synchronizeRuntime(existing) end
            return existing, existingError
        end

        local plan
        local planError
        if request.planId == nil then
            plan, planError = normalize(core.plan({
                domain = 'group',
                subjectId = request.groupId,
                idempotencyKey = 'group-delete:' .. requestId,
                reason = request.reason,
                context = { deletionRequestId = requestId }
            }))
        else
            plan, planError = normalize(core.get(request.planId))
        end
        if not plan then return repository:getGroupDeletion(requestId), planError end

        local applied, applyError = repository:applyGroupDeletionPlan(requestId, plan)
        if not applied then return nil, applyError end
        synchronizeRuntime(applied)
        if applied.state ~= 'dissolving' then return applied, nil end

        local processed, processError = normalize(core.process(plan.planId))
        if not processed then
            local refreshed, refreshError = normalize(core.get(plan.planId))
            if not refreshed then
                return applied, processError or refreshError
            end
            plan = refreshed
        else
            plan = processed
        end
        local reconciled, reconcileError = repository:applyGroupDeletionPlan(requestId, plan)
        if not reconciled then return nil, reconcileError end
        synchronizeRuntime(reconciled)
        return reconciled, processError
    end

    function coordinator:reconcile(maximum)
        local requests, listError = repository:listGroupDeletions(maximum)
        if not requests then return nil, listError end
        local reportValue = {
            examined = #requests,
            deleted = 0,
            blocked = 0,
            pending = 0,
            failed = 0
        }
        for _, requestId in ipairs(requests) do
            local result, reconcileError = self:advance(requestId)
            if result then
                if result.state == 'deleted' then
                    reportValue.deleted = reportValue.deleted + 1
                elseif result.state == 'blocked' then
                    reportValue.blocked = reportValue.blocked + 1
                elseif result.state == 'failed' then
                    reportValue.failed = reportValue.failed + 1
                else
                    reportValue.pending = reportValue.pending + 1
                end
            else
                reportValue.failed = reportValue.failed + 1
            end
            if reconcileError then report('group_deletion_reconcile', reconcileError) end
        end
        return reportValue, nil
    end

    return coordinator
end

return createGroupDeletions
end
