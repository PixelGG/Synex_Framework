local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.sagaRuntime = function(deps)
    local foundation = assert(deps.foundation, 'saga runtime requires foundation')
    local platform = assert(deps.platform, 'saga runtime requires platform')
    local store = assert(deps.sagas, 'saga runtime requires saga persistence')
    local audit = assert(deps.audit, 'saga runtime requires audit persistence')
    local leases = assert(deps.leases, 'saga runtime requires cluster leases')
    local owners = assert(deps.owners, 'saga runtime requires owner registry')
    local instanceId = assert(deps.instanceId, 'saga runtime requires an instance ID')
    local enabled = deps.enabled ~= false
    local logger = foundation.logger
    local metrics = foundation.metrics
    local definitions = {}
    local definitionCount = 0
    local dispatching = false
    local lastDispatch = nil

    local function plainObject(value)
        return type(value) == 'table' and getmetatable(value) == nil
    end

    local function exactKeys(value, allowed)
        if not plainObject(value) then return false end
        for key in pairs(value) do if type(key) ~= 'string' or not allowed[key] then return false end end
        return true
    end

    local function validName(value, maximum)
        return type(value) == 'string' and #value >= 1 and #value <= maximum
            and value:match('^[a-z][a-z0-9_.%-]*$') ~= nil
            and not value:match('[%._%-]$') and not value:match('[%._%-][%._%-]')
    end

    local function integer(value, defaultValue, minimum, maximum)
        if value == nil then return defaultValue end
        if type(value) ~= 'number' or math.type(value) ~= 'integer' or value < minimum or value > maximum then return nil end
        return value
    end

    local function definitionFor(sagaType)
        local definition = definitions[sagaType]
        if definition and owners:isCurrent(definition.owner, definition.epoch) then return definition end
        return nil
    end

    local runtime = {}

    function runtime:register(owner, epoch, definition)
        if not enabled then return nil, foundation.error('FEATURE_DISABLED', 'The sagas feature is disabled by configuration.') end
        if not owners:isCurrent(owner, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The saga handler owner restarted.') end
        if not exactKeys(definition, { name = true, timeoutMs = true, steps = true })
            or not validName(definition.name, 96) or type(definition.steps) ~= 'table'
            or #definition.steps < 1 or #definition.steps > 32 then
            return nil, foundation.error('INVALID_SAGA_DEFINITION', 'Saga definition shape, name, or steps are invalid.')
        end
        local workflowTimeoutMs = integer(definition.timeoutMs, 300000, 1000, 86400000)
        if not workflowTimeoutMs then return nil, foundation.error('INVALID_SAGA_DEFINITION', 'Saga timeout is invalid.') end
        if definitionFor(definition.name) then return nil, foundation.error('SAGA_HANDLER_CONFLICT', 'The saga type already has an active handler.') end
        if definitionCount >= 512 then return nil, foundation.error('SAGA_HANDLER_LIMIT', 'The saga handler registry is full.') end
        local normalizedSteps, names = {}, {}
        for index, step in ipairs(definition.steps) do
            if not exactKeys(step, {
                name = true, run = true, compensate = true, timeoutMs = true,
                maxAttempts = true, compensationAttempts = true, retryDelayMs = true
            }) or not validName(step.name, 96) or names[step.name]
                or type(step.run) ~= 'function' or type(step.compensate) ~= 'function' then
                return nil, foundation.error('INVALID_SAGA_DEFINITION', ('Saga step %d is invalid.'):format(index))
            end
            local timeoutMs = integer(step.timeoutMs, 10000, 100, 30000)
            local maxAttempts = integer(step.maxAttempts, 3, 1, 10)
            local compensationAttempts = integer(step.compensationAttempts, maxAttempts, 1, 10)
            local retryDelayMs = integer(step.retryDelayMs, 1000, 100, 60000)
            if not timeoutMs or not maxAttempts or not compensationAttempts or not retryDelayMs then
                return nil, foundation.error('INVALID_SAGA_DEFINITION', ('Saga step %d limits are invalid.'):format(index))
            end
            names[step.name] = true
            normalizedSteps[index] = {
                name = step.name, run = step.run, compensate = step.compensate,
                timeoutMs = timeoutMs, maxAttempts = maxAttempts,
                compensationAttempts = compensationAttempts, retryDelayMs = retryDelayMs
            }
        end
        local token = foundation.nextId('saga_handler')
        local entry = {
            owner = owner, epoch = epoch, token = token, name = definition.name,
            timeoutMs = workflowTimeoutMs, steps = normalizedSteps
        }
        definitions[definition.name] = entry
        definitionCount = definitionCount + 1
        local _, trackError = owners:track(owner, epoch, 'saga_handler', token, function()
            if definitions[definition.name] == entry then
                definitions[definition.name] = nil
                definitionCount = math.max(0, definitionCount - 1)
            end
        end)
        if trackError then
            definitions[definition.name] = nil
            definitionCount = math.max(0, definitionCount - 1)
            return nil, trackError
        end
        return token, nil
    end

    local function deadlineAfter(milliseconds)
        return os.date('!%Y-%m-%d %H:%M:%S', os.time() + math.ceil(milliseconds / 1000))
    end

    local function auditLifecycle(actor, action, sagaId, traceId, context)
        local appended, auditError = audit:append({
            actorType = 'resource', actorId = actor, action = action,
            targetType = 'saga', targetId = sagaId, traceId = traceId,
            context = context or {}
        })
        if not appended then
            metrics:increment('synex_saga_audit_total', { result = 'failed' })
            logger:error('saga audit append failed', { sagaId = sagaId, action = action, code = auditError.code })
            return nil, auditError
        end
        metrics:increment('synex_saga_audit_total', { result = 'written' })
        return true, nil
    end

    function runtime:start(owner, sagaType, correlationId, context, options, traceId)
        if not enabled then return nil, foundation.error('FEATURE_DISABLED', 'The sagas feature is disabled by configuration.') end
        local definition = definitionFor(sagaType)
        if not definition then return nil, foundation.error('SAGA_HANDLER_UNAVAILABLE', 'No active handler owns this saga type.', { retryable = true }) end
        options = options == nil and {} or options
        if not exactKeys(options, { deadlineAt = true }) or (options.deadlineAt ~= nil
            and (type(options.deadlineAt) ~= 'string' or #options.deadlineAt < 19 or #options.deadlineAt > 32
                or not options.deadlineAt:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d'))) then
            return nil, foundation.error('INVALID_SAGA', 'Saga start options are invalid.')
        end
        local started, startError = store:start(sagaType, correlationId, context, {
            deadlineAt = options.deadlineAt or deadlineAfter(definition.timeoutMs)
        })
        if not started then return nil, startError end
        auditLifecycle(owner, 'saga.started', started.publicId, traceId, {
            sagaType = sagaType, correlationId = tostring(correlationId):sub(1, 128)
        })
        return started, nil
    end

    local function invokeOwned(definition, handler, ...)
        if not owners:isCurrent(definition.owner, definition.epoch) then
            return nil, foundation.error('SAGA_HANDLER_UNAVAILABLE', 'The saga handler owner restarted.', { retryable = true })
        end
        local invocation = { cancelled = false }
        local token, beginError = owners:beginOperation(definition.owner, definition.epoch, function()
            invocation.cancelled = true
        end)
        if not token then return nil, beginError end
        local started = foundation.monotonicMs()
        local ok, value, handlerError = foundation.safeCall(handler, ...)
        owners:finishOperation(definition.owner, definition.epoch, token)
        local elapsed = math.max(0, foundation.monotonicMs() - started)
        if invocation.cancelled then
            return nil, foundation.error('REQUEST_ABORTED', 'The saga handler was aborted during resource quiesce.', { retryable = true }), elapsed
        end
        if not ok then
            return nil, foundation.error('SAGA_HANDLER_FAILED', 'The saga handler raised an error.', {
                retryable = true, details = tostring(value):sub(1, 512)
            }), elapsed
        end
        if handlerError ~= nil or value == nil then
            return nil, type(handlerError) == 'table' and handlerError
                or foundation.error('SAGA_HANDLER_FAILED', 'The saga handler reported failure.', { retryable = true }), elapsed
        end
        return value, nil, elapsed
    end

    local function appendEvent(saga, definition, command, traceId)
        command.publicId = saga.publicId
        command.expectedVersion = saga.version
        command.context = command.context or saga.context
        local persisted, persistError = store:appendRuntimeEvent(command)
        if not persisted then return nil, persistError end
        saga.version = persisted.version
        saga.currentStep = persisted.currentStep
        saga.state = persisted.state
        saga.context = command.context
        saga.ageMs = 0
        auditLifecycle(definition.owner, 'saga.' .. command.eventType, saga.publicId, traceId, {
            sagaType = saga.sagaType, step = command.stepName,
            attempt = command.attempt, state = command.nextState
        })
        return persisted, nil
    end

    local function historyFor(saga, stepName, phase)
        local history = { maximumAttempt = 0, latest = nil, succeeded = nil, compensated = false, started = false }
        for _, event in ipairs(saga.steps) do
            local eventPhase = type(event.payload) == 'table' and event.payload.phase or 'forward'
            if event.name == stepName and (event.event == 'compensated' or eventPhase == phase) then
                history.maximumAttempt = math.max(history.maximumAttempt, event.attempt or 1)
                history.latest = event
                if event.event == 'started' then history.started = true end
                if event.event == 'succeeded' then history.succeeded = event.payload end
                if event.event == 'compensated' then history.compensated = true end
            end
        end
        return history
    end

    local function retryAttempt(history, step, compensation)
        local maximum = compensation and step.compensationAttempts or step.maxAttempts
        local attempt = math.max(1, history.maximumAttempt)
        if history.latest and history.latest.event == 'failed' then attempt = attempt + 1 end
        if attempt > maximum then return nil, 0 end
        if history.latest and history.latest.event == 'failed' then
            local exponent = math.min(attempt - 2, 6)
            return attempt, math.min(60000, step.retryDelayMs * (2 ^ exponent))
        end
        return attempt, 0
    end

    local function compensatableSteps(saga, definition)
        local result = {}
        for index, step in ipairs(definition.steps) do
            local forward = historyFor(saga, step.name, 'forward')
            local compensation = historyFor(saga, step.name, 'compensation')
            if (forward.started or forward.succeeded) and not compensation.compensated then
                result[#result + 1] = { index = index, step = step, forward = forward, compensation = compensation }
            end
        end
        return result
    end

    local function failure(code, message, retryable, traceId)
        return { code = code, message = message, retryable = retryable == true, traceId = traceId }
    end

    local function runCompensation(saga, definition)
        local pending = compensatableSteps(saga, definition)
        if #pending == 0 then
            return nil, foundation.error('SAGA_DATA_INVALID', 'Compensating saga has no compensatable history.')
        end
        local target = pending[#pending]
        local attempt, delay = retryAttempt(target.compensation, target.step, true)
        if not attempt then
            return nil, foundation.error('SAGA_COMPENSATION_EXHAUSTED', 'Saga compensation attempts are exhausted.')
        end
        if saga.ageMs < delay then return { deferred = true }, nil end
        local traceId = foundation.nextId('trace')
        local idempotencyKey = saga.publicId
        if not (target.compensation.latest and target.compensation.latest.event == 'started'
            and target.compensation.latest.attempt == attempt) then
            local started, startError = appendEvent(saga, definition, {
                stepName = target.step.name, eventType = 'started', attempt = attempt,
                nextState = 'compensating', payload = {
                    phase = 'compensation', idempotencyKey = idempotencyKey, traceId = traceId
                }
            }, traceId)
            if not started then return nil, startError end
        end
        local result, handlerError, elapsed = invokeOwned(definition, target.step.compensate,
            foundation.copy(saga.context), foundation.copy(target.forward.succeeded or {}), foundation.readonly({
                sagaId = saga.publicId, sagaType = saga.sagaType, step = target.step.name,
                phase = 'compensation', attempt = attempt, idempotencyKey = idempotencyKey,
                traceId = traceId, timeoutMs = target.step.timeoutMs
            }))
        if elapsed and elapsed > target.step.timeoutMs then
            result = nil
            handlerError = failure('SAGA_STEP_TIMEOUT', 'Saga compensation exceeded its timeout.', true, traceId)
        end
        if not result then
            local terminal = attempt >= target.step.compensationAttempts
            local persisted, persistError = appendEvent(saga, definition, {
                stepName = target.step.name, eventType = 'failed', attempt = attempt,
                nextState = terminal and 'failed' or 'compensating', terminal = terminal,
                payload = { phase = 'compensation', traceId = traceId }, error = handlerError
            }, traceId)
            if not persisted then return nil, persistError end
            return { failed = true, terminal = terminal }, nil
        end
        if result and (not plainObject(result) or (result.context ~= nil and not plainObject(result.context))) then
            handlerError = foundation.error('SAGA_HANDLER_RESULT_INVALID', 'Saga compensation must return an object result.')
            result = nil
        end
        if not result then
            local terminal = attempt >= target.step.compensationAttempts
            local persisted, persistError = appendEvent(saga, definition, {
                stepName = target.step.name, eventType = 'failed', attempt = attempt,
                nextState = terminal and 'failed' or 'compensating', terminal = terminal,
                payload = { phase = 'compensation', traceId = traceId }, error = handlerError
            }, traceId)
            if not persisted then return nil, persistError end
            return { failed = true, terminal = terminal }, nil
        end
        local terminal = #pending == 1
        local persisted, persistError = appendEvent(saga, definition, {
            stepName = target.step.name, eventType = 'compensated', attempt = attempt,
            nextState = terminal and 'failed' or 'compensating', terminal = terminal,
            context = result.context or saga.context,
            payload = { phase = 'compensation', output = result.output, traceId = traceId }
        }, traceId)
        if not persisted then return nil, persistError end
        return { compensated = true, terminal = terminal }, nil
    end

    local function nextForwardStep(saga, definition)
        for index, step in ipairs(definition.steps) do
            local history = historyFor(saga, step.name, 'forward')
            if not history.succeeded then return index, step, history end
        end
        return nil
    end

    local function runForward(saga, definition)
        local index, step, history = nextForwardStep(saga, definition)
        if not step then return nil, foundation.error('SAGA_DATA_INVALID', 'Runnable saga already completed every step.') end
        local pendingCompensation = compensatableSteps(saga, definition)
        if saga.deadlineExpired then
            local terminal = #pendingCompensation == 0
            local traceId = foundation.nextId('trace')
            local persisted, persistError = appendEvent(saga, definition, {
                stepName = step.name, eventType = 'failed', attempt = math.max(1, history.maximumAttempt),
                nextState = terminal and 'failed' or 'compensating', terminal = terminal,
                payload = { phase = 'forward', deadline = true, traceId = traceId },
                error = failure('SAGA_DEADLINE_EXCEEDED', 'Saga deadline was exceeded.', false, traceId)
            }, traceId)
            if not persisted then return nil, persistError end
            return { timedOut = true, terminal = terminal }, nil
        end
        local attempt, delay = retryAttempt(history, step, false)
        if not attempt then return nil, foundation.error('SAGA_RETRY_EXHAUSTED', 'Saga step attempts are exhausted.') end
        if saga.ageMs < delay then return { deferred = true }, nil end
        local traceId = foundation.nextId('trace')
        local idempotencyKey = saga.publicId
        if not (history.latest and history.latest.event == 'started' and history.latest.attempt == attempt) then
            local started, startError = appendEvent(saga, definition, {
                stepName = step.name, eventType = 'started', attempt = attempt, nextState = 'running',
                payload = { phase = 'forward', idempotencyKey = idempotencyKey, traceId = traceId }
            }, traceId)
            if not started then return nil, startError end
        end
        local result, handlerError, elapsed = invokeOwned(definition, step.run,
            foundation.copy(saga.context), foundation.readonly({
                sagaId = saga.publicId, sagaType = saga.sagaType, correlationId = saga.correlationId,
                step = step.name, phase = 'forward', attempt = attempt,
                idempotencyKey = idempotencyKey, traceId = traceId, timeoutMs = step.timeoutMs
            }))
        if elapsed and elapsed > step.timeoutMs then
            result = nil
            handlerError = failure('SAGA_STEP_TIMEOUT', 'Saga step exceeded its timeout.', true, traceId)
        end
        if not result then
            local terminalAttempt = attempt >= step.maxAttempts
            local shouldCompensate = terminalAttempt
            local terminal = terminalAttempt and not shouldCompensate
            local persisted, persistError = appendEvent(saga, definition, {
                stepName = step.name, eventType = 'failed', attempt = attempt,
                nextState = terminal and 'failed' or (shouldCompensate and 'compensating' or 'running'),
                terminal = terminal, payload = { phase = 'forward', traceId = traceId }, error = handlerError
            }, traceId)
            if not persisted then return nil, persistError end
            return { failed = true, terminal = terminal, compensating = shouldCompensate }, nil
        end
        if result and (not plainObject(result) or (result.context ~= nil and not plainObject(result.context))) then
            handlerError = foundation.error('SAGA_HANDLER_RESULT_INVALID', 'Saga handlers must return an object with optional object context.')
            result = nil
        end
        if not result then
            local terminalAttempt = attempt >= step.maxAttempts
            local persisted, persistError = appendEvent(saga, definition, {
                stepName = step.name, eventType = 'failed', attempt = attempt,
                nextState = terminalAttempt and 'compensating' or 'running',
                payload = { phase = 'forward', traceId = traceId }, error = handlerError
            }, traceId)
            if not persisted then return nil, persistError end
            return { failed = true, terminal = false, compensating = terminalAttempt }, nil
        end
        local completed = index == #definition.steps
        local persisted, persistError = appendEvent(saga, definition, {
            stepName = step.name, eventType = 'succeeded', attempt = attempt,
            nextState = completed and 'completed' or 'running', terminal = completed, clearError = completed,
            context = result.context or saga.context,
            payload = { phase = 'forward', output = result.output, traceId = traceId }
        }, traceId)
        if not persisted then return nil, persistError end
        return { succeeded = true, completed = completed }, nil
    end

    local function processCandidate(candidate)
        local definition = definitionFor(candidate.sagaType)
        if not definition then return { deferred = true, handlerUnavailable = true }, nil end
        local saga, loadError = store:load(candidate.publicId)
        if not saga then return nil, loadError end
        if saga.state == 'compensating' then return runCompensation(saga, definition) end
        return runForward(saga, definition)
    end

    function runtime:dispatchBatch(maximum)
        if not enabled then return { enabled = false, claimed = 0 }, nil end
        if dispatching then return nil, foundation.error('SAGA_DISPATCH_BUSY', 'The local saga worker is already running.', { retryable = true }) end
        maximum = integer(maximum, 10, 1, 50)
        if not maximum then return nil, foundation.error('INVALID_ARGUMENT', 'Saga dispatch batch size is invalid.') end
        dispatching = true
        local report = { claimed = 0, processed = 0, deferred = 0, failed = 0, leaseBusy = 0 }
        local firstError = nil
        local ok, unexpected = xpcall(function()
            local candidates, candidateError = store:candidates(maximum)
            if not candidates then firstError = candidateError return end
            report.claimed = #candidates
            for _, candidate in ipairs(candidates) do
                local leaseOwner = instanceId .. ':saga'
                local lease, leaseError = leases:acquire('saga:' .. candidate.publicId, leaseOwner, 45)
                if not lease then
                    if leaseError and leaseError.code == 'LEASE_BUSY' then report.leaseBusy = report.leaseBusy + 1
                    else report.failed = report.failed + 1; firstError = firstError or leaseError end
                else
                    local processedOk, result, processError = foundation.safeCall(processCandidate, candidate)
                    local released, releaseError = leases:release(lease)
                    if not released then firstError = firstError or releaseError; report.failed = report.failed + 1 end
                    if not processedOk or not result then
                        local failureValue = processedOk and processError or result
                        firstError = firstError or (type(failureValue) == 'table' and failureValue
                            or foundation.error('SAGA_DISPATCH_FAILED', 'Saga processing raised an unexpected error.'))
                        report.failed = report.failed + 1
                    elseif result.deferred then report.deferred = report.deferred + 1
                    else report.processed = report.processed + 1 end
                end
            end
        end, debug.traceback)
        dispatching = false
        if not ok then
            firstError = foundation.error('SAGA_DISPATCH_FAILED', 'Saga dispatch raised an unexpected error.', {
                details = tostring(unexpected):sub(1, 512), retryable = true
            })
            report.failed = report.failed + 1
        end
        lastDispatch = {
            at = foundation.utcIso(), claimed = report.claimed, processed = report.processed,
            deferred = report.deferred, failed = report.failed, leaseBusy = report.leaseBusy
        }
        metrics:increment('synex_saga_dispatch_total', { result = firstError and 'failed' or 'complete' })
        if firstError then return report, firstError end
        return report, nil
    end

    function runtime:get(publicId)
        local saga, err = store:load(publicId)
        if not saga then return nil, err end
        saga.databaseId = nil
        saga.context = foundation.redact(saga.context)
        for _, event in ipairs(saga.steps) do
            event.payload = foundation.redact(event.payload)
            event.error = foundation.redact(event.error)
        end
        return saga, nil
    end

    function runtime:snapshot()
        local registered = {}
        for name, definition in pairs(definitions) do
            if owners:isCurrent(definition.owner, definition.epoch) then
                registered[#registered + 1] = { name = name, owner = definition.owner, steps = #definition.steps }
            end
        end
        table.sort(registered, function(a, b) return a.name < b.name end)
        local persisted, persistedError = store:snapshot()
        return {
            enabled = enabled,
            handlers = registered,
            dispatching = dispatching,
            lastDispatch = foundation.copy(lastDispatch),
            persisted = persisted or { available = false, error = persistedError and persistedError.code or 'UNAVAILABLE' }
        }
    end

    return runtime
end
