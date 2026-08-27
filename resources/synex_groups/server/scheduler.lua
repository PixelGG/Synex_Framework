return function(Foundation)
return function(api, dependencies, options)
    options = options or {}
    if type(api) ~= 'table' or type(api.Scheduler) ~= 'table'
        or not Foundation.isCallable(api.Scheduler.every)
        or not Foundation.isCallable(api.Scheduler.cancel)
        or type(dependencies) ~= 'table'
        or type(dependencies.outboxDispatcher) ~= 'table'
        or type(dependencies.database) ~= 'table'
        or type(dependencies.runtimeIndex) ~= 'table'
        or not Foundation.isCallable(dependencies.loadRuntimeCharacter)
        or type(dependencies.groupCreationApprovals) ~= 'table'
        or type(dependencies.groupDeletions) ~= 'table'
        or type(options.tokens) ~= 'table'
        or type(options.pendingCancellations) ~= 'table'
        or not Foundation.isCallable(options.isCurrent)
        or not Foundation.isCallable(options.isReady) then
        return nil, Foundation.domainError('WORKER_REGISTRATION_FAILED',
            'The Groups worker scheduler dependencies are incomplete.')
    end
    if not options.isCurrent() then
        return nil, Foundation.domainError('STALE_RESOURCE',
            'The Groups worker registration generation is stale.', true)
    end

    local function cancelToken(name, token)
        local invoked, _, cancelError = pcall(api.Scheduler.cancel, token)
        if not invoked or cancelError ~= nil then
            options.pendingCancellations[name] = token
            return nil, Foundation.domainError('WORKER_CANCELLATION_FAILED',
                'A partial Groups worker batch could not be cancelled safely.', true)
        end
        options.pendingCancellations[name] = nil
        options.tokens[name] = nil
        return true, nil
    end

    local pendingNames = {}
    for name in pairs(options.pendingCancellations) do
        pendingNames[#pendingNames + 1] = name
    end
    table.sort(pendingNames)
    for _, name in ipairs(pendingNames) do
        local cancelled, cancelError = cancelToken(
            name, options.pendingCancellations[name])
        if not cancelled then return nil, cancelError end
        if not options.isCurrent() then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The Groups worker registration generation is stale.', true)
        end
    end

    local workers = {
        {
            name = 'synex_groups.outbox_dispatcher', delay = 1000,
            handler = function()
                local claimToken, claimError = api.Ids.next('outbox_claim')
                if not claimToken then return nil, claimError end
                return dependencies.outboxDispatcher:dispatchBatch(claimToken,
                    function(topic, payload, publishOptions)
                        return api.Events.publishOutbox(topic, payload, {
                            traceId = publishOptions.traceId,
                            eventId = publishOptions.eventId,
                            aggregateId = publishOptions.aggregateId,
                            schemaVersion = publishOptions.schemaVersion
                        })
                    end, { maximum = 25 })
            end
        },
        {
            name = 'synex_groups.audit_dispatcher', delay = 5000,
            handler = function()
                local claimToken, claimError = api.Ids.next('groups_audit')
                if not claimToken then return nil, claimError end
                return dependencies.database:dispatchAuditBatch(claimToken, function(entry)
                    return api.Audit.append(entry)
                end, 25)
            end
        },
        {
            name = 'synex_groups.lifecycle_maintenance', delay = 30000,
            handler = function()
                local report, maintenanceError = dependencies.database:maintain({ maximum = 100 })
                if not report then return nil, maintenanceError end
                if tonumber(report.assignments) and tonumber(report.assignments) > 0 then
                    local refreshed, refreshError = dependencies.runtimeIndex:refreshAll(
                        dependencies.loadRuntimeCharacter)
                    if not refreshed then return nil, refreshError end
                end
                return report, nil
            end
        },
        {
            name = 'synex_groups.creation_reconciliation', delay = 5000,
            handler = function() return dependencies.groupCreationApprovals:reconcile(16) end
        },
        {
            name = 'synex_groups.deletion_reconciliation', delay = 5000,
            handler = function() return dependencies.groupDeletions:reconcile(16) end
        }
    }
    local newlyScheduled = {}
    local function cancelNew(runtimeError)
        for index = #newlyScheduled, 1, -1 do
            local scheduled = newlyScheduled[index]
            local cancelled, cancelError = cancelToken(scheduled.name, scheduled.token)
            if not cancelled then runtimeError = cancelError end
        end
        return nil, runtimeError
    end
    for _, worker in ipairs(workers) do
        if not options.tokens[worker.name] then
            local selectedWorker = worker
            local token, scheduleError = api.Scheduler.every(selectedWorker.delay, function()
                if not options.isCurrent() or not options.isReady() then return true, nil end
                return selectedWorker.handler()
            end, { name = selectedWorker.name })
            if not token then
                return cancelNew(scheduleError or Foundation.domainError(
                    'WORKER_REGISTRATION_FAILED',
                    'A Groups worker could not be registered.', true))
            end
            options.tokens[selectedWorker.name] = token
            newlyScheduled[#newlyScheduled + 1] = { name = selectedWorker.name, token = token }
            if not options.isCurrent() then
                return cancelNew(Foundation.domainError('STALE_RESOURCE',
                    'The Groups worker registration generation is stale.', true))
            end
        end
    end
    return true, nil
end
end
