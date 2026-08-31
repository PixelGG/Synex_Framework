SynexInteractActionGraph = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')
local Foundation = assert(SynexInteractFoundation, 'interact foundation must be loaded first')

local presentationNodes = {
    faceTarget = true, moveToSlot = true, animation = true, scenario = true,
    progress = true, sound = true, interactionCue = true, stopAnimation = true,
}
local verificationNodes = {
    verifyLease = true, verifyContext = true, verifyTarget = true, verifyPolicy = true,
}
local cleanupNodes = {
    stopAnimation = true, releaseSlot = true, releaseLease = true,
    releaseLocks = true, removeTemporaryEntity = true,
}
local ASYNC_POLL_INTERVAL_MS = 10
local COMPLETE_SIGNAL = {}
local executionOutcomes = {
    COMPLETED = 'completed', ABORTED = 'aborted', FAILED = 'failed',
    TIMED_OUT = 'timed_out',
}

function SynexInteractActionGraph.create(options)
    options = options or {}
    local registry = assert(options.registry, 'graph runtime requires registry')
    local now = assert(options.now, 'graph runtime requires monotonic time')
    local wait = options.wait or Wait
    local spawn = options.spawn or CreateThread
    local nextId = assert(options.nextId, 'graph runtime requires IDs')
    local emit = assert(options.emit, 'graph runtime requires client presentation transport')
    local verify = options.verify or function() return true end
    local slots = assert(options.slots, 'graph runtime requires slot state')
    local locks = assert(options.locks, 'graph runtime requires actor locks')
    local sessions = assert(options.sessions, 'graph runtime requires sessions')
    local observability = assert(options.observability, 'graph runtime requires observability')
    local onFinished = options.onFinished or function() end
    local leaseReleaser = Validation.isCallable(options.releaseLease)
        and options.releaseLease or nil
    local executions, executionCount = {}, 0
    local runtime = {}

    local function failure(code, message, retryable, details)
        local _, value = Validation.failure(code, message, retryable, details)
        return value
    end

    local function actorKeys(session)
        local values = {}
        for _, role in pairs(session.roles or {}) do
            for key, member in pairs(role.members or {}) do
                if member.ready ~= false then values[#values + 1] = key end
            end
        end
        table.sort(values)
        return values
    end

    local function participants(session)
        local values = {}
        for _, role in pairs(session.roles or {}) do
            for _, member in pairs(role.members or {}) do
                if member.ready ~= false then
                    values[#values + 1] = { source = member.source,
                        sourceGeneration = member.sourceGeneration, role = member.role }
                end
            end
        end
        table.sort(values, function(left, right)
            if left.source == right.source then return left.sourceGeneration < right.sourceGeneration end
            return left.source < right.source
        end)
        return values
    end

    local function current(execution)
        local resolved = registry.resolveIntent(execution.intentKey, execution.bundleRevision)
        return resolved and resolved.bundle.ownerResource == execution.ownerResource
            and resolved.bundle.ownerEpoch == execution.ownerEpoch
            and resolved.graph.key == execution.graphKey
    end

    local function cancelled(execution, branch)
        while execution.paused and not execution.cancelled
            and not execution.cleaned and not (branch and branch.cancelled)
            and current(execution) and now() <= execution.deadlineAt do
            wait(25)
        end
        if execution.cleaned or execution.cancelled or branch and branch.cancelled then
            return true, failure('INTERACT_CANCELLED',
                'The interaction graph was cancelled.', false, {
                    reason = execution.cancelReason
                        or branch and branch.cancelled and 'BRANCH_CANCELLED'
                        or execution.cleaned and 'EXECUTION_FINISHED'
                        or 'USER_CANCELLED',
                    committed = execution.committed == true,
                })
        end
        if not current(execution) then
            return true, failure('INTERACT_GRAPH_STALE',
                'The interaction graph definition changed.', false)
        end
        if now() > execution.deadlineAt then
            return true, failure('INTERACT_TIMEOUT',
                'The interaction graph timed out.', false)
        end
        return false
    end

    local function invokeAdapter(execution, node, phase)
        if not Validation.identifier(node.adapter) then
            return nil, failure('INTERACT_ADAPTER_MISSING',
                'A typed interaction adapter was not configured.', false)
        end
        local adapter = registry.getAdapter(node.adapter)
        if not adapter or adapter.owner ~= execution.ownerResource
            or adapter.epoch ~= execution.ownerEpoch then
            return nil, failure('INTERACT_ADAPTER_STALE',
                'The typed interaction adapter is unavailable.', true)
        end
        local request = {
            phase = phase, executionId = execution.id, sessionId = execution.sessionId,
            traceId = execution.traceId, intentKey = execution.intentKey,
            target = Validation.copy(execution.target), nodeKey = node.key,
            request = Validation.copy(node.request or {}),
            operation = {
                service = node.service, version = node.version, method = node.method,
                contract = node.contract, timeoutMs = node.timeoutMs,
            },
            idempotencyKey = execution.id .. ':' .. (node.commitKey or node.key),
            committed = execution.committed,
        }
        local timeoutMs = type(adapter.definition) == 'table'
            and adapter.definition.timeoutMs or Limits.graphNodeTimeoutMs
        if node.timeoutMs ~= nil then timeoutMs = math.min(timeoutMs, node.timeoutMs) end
        local started = now()
        local value, operationError = Foundation.boundedCall(adapter.handler, {
            now = now, wait = wait, spawn = spawn, timeoutMs = timeoutMs,
            timeoutCode = phase == 'AWAIT' and 'INTERACT_GRAPH_TIMEOUT'
                or 'INTERACT_ADAPTER_TIMEOUT',
            timeoutMessage = phase == 'AWAIT'
                and 'The typed interaction event wait timed out.'
                or 'The typed interaction adapter timed out.',
            retryable = phase ~= 'COMMIT',
        }, request)
        observability.observe('adapter_duration_ms', {
            provider_kind = adapter.kind or 'adapter', outcome = value and 'success' or 'failure',
        }, math.max(0, now() - started))
        if value == nil then return nil, type(operationError) == 'table' and operationError
            or failure('INTERACT_DOMAIN_REJECTED', 'The domain adapter rejected the interaction.', false) end
        return value, nil
    end

    local function finishNode(node, startedAt, ok, value)
        Foundation.protect(observability.observe, 'graph_node_duration', {
            node_category = node.type,
        }, math.max(0, now() - startedAt))
        return ok, value
    end

    local runNode

    local function runConcurrent(execution, node, race, branch, depth, cleanupMode)
        local children = node.children or {}
        if #children == 0 then return true end
        local group = { remaining = #children, results = {}, branches = {} }
        for index = 1, #children do group.branches[index] = { cancelled = false } end
        for index, key in ipairs(children) do
            local childBranch = group.branches[index]
            spawn(function()
                local ok, value = Foundation.protect(
                    runNode, execution, key, childBranch, depth, cleanupMode)
                group.results[index] = { ok = ok, value = value }
                group.remaining = group.remaining - 1
                if ok and value == COMPLETE_SIGNAL and group.terminal == nil then
                    group.terminal = index
                    for other, candidate in ipairs(group.branches) do
                        if other ~= index then candidate.cancelled = true end
                    end
                elseif race and ok and group.winner == nil then
                    group.winner = index
                    for other, candidate in ipairs(group.branches) do
                        if other ~= index then candidate.cancelled = true end
                    end
                end
            end)
        end
        while group.remaining > 0 and group.terminal == nil
            and (not race or group.winner == nil) do
            local stopped, stopError = cancelled(execution, branch)
            if stopped then
                for _, child in ipairs(group.branches) do child.cancelled = true end
                return nil, stopError
            end
            wait(ASYNC_POLL_INTERVAL_MS)
        end
        if group.terminal then
            for other, candidate in ipairs(group.branches) do
                if other ~= group.terminal then candidate.cancelled = true end
            end
            while group.remaining > 0 and (now() <= execution.deadlineAt
                or execution.commitsInFlight > 0) do wait(ASYNC_POLL_INTERVAL_MS) end
            return true, COMPLETE_SIGNAL
        end
        if race and group.winner then
            for other, candidate in ipairs(group.branches) do
                if other ~= group.winner then candidate.cancelled = true end
            end
            while group.remaining > 0 and (now() <= execution.deadlineAt
                or execution.commitsInFlight > 0) do wait(ASYNC_POLL_INTERVAL_MS) end
            return true, group.results[group.winner].value
        end
        if race then
            return nil, (group.results[1] and group.results[1].value)
                or failure('INTERACT_GRAPH_FAILED', 'Every race branch failed.', false)
        end
        for index = 1, #children do
            if not group.results[index] or not group.results[index].ok then
                return nil, group.results[index] and group.results[index].value
                    or failure('INTERACT_GRAPH_FAILED', 'A parallel branch failed.', false)
            end
        end
        return true
    end

    local function emitPresentation(execution, node, branch)
        execution.sequence = execution.sequence + 1
        local command = {
            schemaVersion = 1, sessionId = execution.sessionId,
            executionId = execution.id, nodeKey = node.key,
            sequence = execution.sequence, type = node.type,
            presentation = Validation.copy(node.presentation or {}),
            target = Validation.copy(execution.target),
        }
        local duration = tonumber(node.durationMs)
            or tonumber(command.presentation and command.presentation.durationMs) or 0
        command.serverDurationMs = math.max(0, math.min(60000, math.floor(duration)))
        execution.pendingAcks[node.key] = { sequence = execution.sequence,
            createdAt = now(), results = {} }
        for _, participant in ipairs(execution.participants) do
            local sent, sendError = Foundation.protect(emit, participant.source, command)
            if sent == nil then return nil, sendError end
        end
        -- Client acknowledgement is presentation telemetry only. Authority advances by server time.
        local remaining = command.serverDurationMs
        while remaining > 0 do
            local step = math.min(remaining, 50)
            wait(step)
            remaining = remaining - step
            local stopped, stopError = cancelled(execution, branch)
            if stopped then return nil, stopError end
        end
        execution.pendingAcks[node.key] = nil
        return true
    end

    runNode = function(execution, key, branch, depth, cleanupMode)
        if not cleanupMode then
            local stopped, stopError = cancelled(execution, branch)
            if stopped then return nil, stopError end
        end
        depth = (depth or 0) + 1
        if depth > Limits.maximumGraphDepth then
            return nil, failure('INTERACT_GRAPH_INVALID', 'Graph runtime depth exceeded.', false)
        end
        execution.steps = execution.steps + 1
        if execution.steps > Limits.maximumGraphSteps then
            return nil, failure('INTERACT_GRAPH_INVALID', 'Graph runtime step bound exceeded.', false)
        end
        local node = execution.graph.nodes[key]
        if not node then return nil, failure('INTERACT_GRAPH_INVALID', 'Graph node is unavailable.', false) end
        if cleanupMode and not cleanupNodes[node.type]
            and node.type ~= 'sequence' and node.type ~= 'complete' then
            return nil, failure('INTERACT_GRAPH_INVALID',
                'A cleanup path contains a non-cleanup node.', false)
        end
        execution.currentNode = node.key
        local nodeStartedAt = now()
        observability.trace(execution.traceId, { phase = 'node', node = node.key,
            category = node.type, execution = execution.id })
        observability.increment('graph_node_total', { node_category = node.type }, 1)

        local ok, value = true, nil
        if node.type == 'sequence' then
            for _, child in ipairs(node.children or {}) do
                ok, value = runNode(execution, child, branch, depth, cleanupMode)
                if not ok or value == COMPLETE_SIGNAL then break end
            end
        elseif node.type == 'parallel' then
            ok, value = runConcurrent(execution, node, false, branch, depth, cleanupMode)
        elseif node.type == 'race' then
            ok, value = runConcurrent(execution, node, true, branch, depth, cleanupMode)
        elseif node.type == 'branch' then
            local decision, decisionError = Foundation.protect(verify, 'condition', execution, node)
            if decision == nil then ok, value = nil, decisionError
            else ok, value = runNode(execution,
                decision and node.thenNode or node.elseNode, branch, depth, cleanupMode) end
        elseif node.type == 'retry' then
            ok = nil
            for attempt = 1, node.maxAttempts do
                ok, value = runNode(execution, node.children[1], branch, depth, cleanupMode)
                if ok then break end
                if execution.committed or execution.cancelled then break end
                local retryable = type(value) == 'table' and value.retryable == true
                if type(node.retryableErrors) == 'table' and #node.retryableErrors > 0 then
                    retryable = false
                    for _, code in ipairs(node.retryableErrors) do
                        if type(value) == 'table' and value.code == code then
                            retryable = true
                            break
                        end
                    end
                end
                if not retryable then break end
                if attempt < node.maxAttempts then
                    local remaining = node.backoffMs or 0
                    local interrupted = false
                    while remaining > 0 do
                        local step = math.min(remaining, 50)
                        wait(step)
                        remaining = remaining - step
                        local stopped, stopError = cancelled(execution, branch)
                        if stopped then
                            ok, value, interrupted = nil, stopError, true
                            break
                        end
                    end
                    if interrupted then break end
                end
            end
        elseif node.type == 'timeout' then
            local timed = { done = false, ok = nil, value = nil, cancelled = false }
            spawn(function()
                timed.ok, timed.value = Foundation.protect(
                    runNode, execution, node.children[1], timed, depth, cleanupMode)
                timed.done = true
            end)
            local deadline = now() + node.timeoutMs
            while not timed.done and now() < deadline do wait(ASYNC_POLL_INTERVAL_MS) end
            while not timed.done and execution.commitsInFlight > 0 do
                wait(ASYNC_POLL_INTERVAL_MS)
            end
            if not timed.done then
                timed.cancelled = true
                ok, value = nil, failure('INTERACT_TIMEOUT', 'A graph node timed out.', false)
            else ok, value = timed.ok, timed.value end
        elseif node.type == 'barrier' or node.type == 'participantBarrier' then
            ok, value = Foundation.protect(verify, 'barrier', execution, node)
        elseif node.type == 'awaitEvent' then
            ok, value = invokeAdapter(execution, node, 'AWAIT')
            ok = ok ~= nil
        elseif verificationNodes[node.type] then
            ok, value = Foundation.protect(verify, node.type, execution, node)
        elseif node.type == 'wait' then
            local remaining = node.durationMs
            while remaining > 0 do
                local step = math.min(remaining, 50); wait(step); remaining = remaining - step
                if not cleanupMode then
                    local halt, haltError = cancelled(execution, branch)
                    if halt then ok, value = nil, haltError; break end
                end
            end
        elseif presentationNodes[node.type] then
            ok, value = emitPresentation(execution, node, branch)
        elseif node.type == 'serviceCall' or node.type == 'contractCall' then
            ok, value = invokeAdapter(execution, node, 'EXECUTE')
            ok = ok ~= nil
        elseif node.type == 'commit' then
            local commitKey = node.commitKey or node.key
            if execution.commits[commitKey] then ok, value = true, execution.commits[commitKey]
            else
                local claim = execution.commitClaims[commitKey]
                if claim then
                    while claim.state == 'PENDING' do
                        local stopped, stopError = cancelled(execution, branch)
                        if stopped then ok, value = nil, stopError; break end
                        wait(ASYNC_POLL_INTERVAL_MS)
                    end
                    if ok ~= nil then
                        if claim.state == 'COMMITTED' then ok, value = true, claim.value
                        else ok, value = nil, claim.error end
                    end
                else
                    claim = { state = 'PENDING' }
                    execution.commitClaims[commitKey] = claim
                    execution.state = 'COMMITTING'
                    execution.commitsInFlight = execution.commitsInFlight + 1
                    local guarded, guardError = Foundation.protect(
                        verify, 'commit', execution, node)
                    local result, adapterError = guarded == true and true or nil,
                        guarded == true and nil or guardError or failure(
                            'INTERACT_LEASE_STALE',
                            'The mandatory commit authority fence failed.', false)
                    if result ~= nil and node.adapter then
                        result, adapterError = invokeAdapter(execution, node, 'COMMIT')
                    end
                    execution.commitsInFlight = math.max(0, execution.commitsInFlight - 1)
                    if result == nil then
                        claim.state, claim.error = 'FAILED', adapterError
                        execution.commitClaims[commitKey] = nil
                        execution.state = 'RUNNING'
                        ok, value = nil, adapterError
                    else
                        local committedValue = Validation.copy(result) or true
                        execution.committed = true
                        execution.commits[commitKey] = committedValue
                        claim.state, claim.value = 'COMMITTED', committedValue
                        execution.state = 'RUNNING'
                        ok, value = true, result
                    end
                end
            end
        elseif node.type == 'releaseSlot' then
            slots.cleanupSession(execution.sessionId); ok = true
        elseif node.type == 'releaseLease' then
            if execution.leaseReleased then ok = true
            elseif not leaseReleaser then
                ok, value = nil, failure('INTERACT_UNAVAILABLE',
                    'The interaction lease releaser is unavailable.', true)
            else
                local released, releaseError = Foundation.protect(leaseReleaser,
                    execution.sessionId, execution.leaseId, 'GRAPH_RELEASED')
                if released == nil then ok, value = nil, releaseError
                else execution.leaseReleased, ok, value = true, true, released end
            end
        elseif node.type == 'releaseLocks' then
            locks.release(execution.sessionId, execution.id); ok = true
        elseif node.type == 'removeTemporaryEntity' then
            ok, value = invokeAdapter(execution, node, 'CLEANUP_TEMPORARY')
            ok = ok ~= nil
        elseif node.type == 'complete' then
            return finishNode(node, nodeStartedAt, true, COMPLETE_SIGNAL)
        elseif node.type == 'fail' then
            return finishNode(node, nodeStartedAt, nil,
                failure(node.code or 'INTERACT_GRAPH_FAILED',
                    'The interaction graph ended in failure.', false))
        else
            return finishNode(node, nodeStartedAt, nil,
                failure('INTERACT_GRAPH_INVALID',
                    'Graph node type is unsupported.', false))
        end
        if not ok then
            if node.cleanup and not cleanupMode then
                local cleanupOk, cleanupError = runNode(
                    execution, node.cleanup, branch, depth, true)
                if not cleanupOk then Foundation.protect(observability.increment,
                    'cleanup_failure_total', { node_category = node.type,
                        outcome = cleanupError.code or 'INTERACT_INTERNAL_ERROR' }, 1) end
            end
            return finishNode(node, nodeStartedAt, nil, value)
        end
        if value == COMPLETE_SIGNAL then
            return finishNode(node, nodeStartedAt, true, COMPLETE_SIGNAL)
        end
        finishNode(node, nodeStartedAt, true, value)
        if node.next then return runNode(execution, node.next, branch, depth, cleanupMode) end
        return true, value
    end

    local function cleanupStep(category, handler, ...)
        local value, operationError = Foundation.protect(handler, ...)
        if value == nil and operationError ~= nil then
            Foundation.protect(observability.increment, 'cleanup_failure_total', {
                node_category = category,
                outcome = type(operationError) == 'table' and operationError.code
                    or 'INTERACT_INTERNAL_ERROR',
            }, 1)
        end
        return value, operationError
    end

    local function cleanup(execution, state, operationError)
        if execution.cleaned then return false end
        execution.cleaned = true
        execution.state = state
        if not execution.leaseReleased and leaseReleaser then
            local released = cleanupStep('releaseLease', leaseReleaser,
                execution.sessionId, execution.leaseId,
                operationError and operationError.code or state)
            if released ~= nil then execution.leaseReleased = true end
        end
        cleanupStep('releaseLocks', locks.release,
            execution.sessionId, execution.id)
        cleanupStep('releaseSlot', slots.cleanupSession, execution.sessionId)
        cleanupStep('sessionFinish', sessions.finish,
            execution.sessionId, state, operationError and operationError.code or nil)
        for _, participant in ipairs(execution.participants) do
            cleanupStep('clientCleanup', emit, participant.source, {
                schemaVersion = 1, type = 'cleanup',
                sessionId = execution.sessionId, executionId = execution.id,
                reason = operationError and operationError.details
                    and operationError.details.reason
                    or operationError and operationError.code or state,
                committed = execution.committed == true,
            })
        end
        executions[execution.id], executionCount = nil, math.max(0, executionCount - 1)
        local terminalMetric = state == 'COMPLETED' and 'graph_completed_total'
            or state == 'ABORTED' and 'graph_cancelled_total'
            or 'graph_failed_total'
        Foundation.protect(observability.increment, terminalMetric, {}, 1)
        Foundation.protect(observability.increment, 'graph_execution_total', {
            outcome = executionOutcomes[state] or 'failed',
        }, 1)
        Foundation.protect(observability.trace, execution.traceId, {
            phase = 'graph_finished', execution = execution.id,
            state = state, committed = execution.committed == true,
        })
        cleanupStep('finishCallback', onFinished, execution, state, operationError)
        cleanupStep('sessionRemove', sessions.remove, execution.sessionId)
        return true
    end

    function runtime.start(session, resolved, lease, context)
        local id, idError = nextId('interact_exec')
        if not Validation.token(id, 8, 96) then return nil, idError or failure(
            'INTERACT_UNAVAILABLE', 'Graph execution ID is unavailable.', true) end
        local actors = actorKeys(session)
        local graphLocks = {}
        for _, channel in ipairs(resolved.graph.locks or {}) do graphLocks[#graphLocks + 1] = channel end
        for _, channel in ipairs(resolved.intent.executionPolicy.lockChannels or {}) do
            graphLocks[#graphLocks + 1] = channel
        end
        table.sort(graphLocks)
        local unique, previous = {}, nil
        for _, channel in ipairs(graphLocks) do
            if channel ~= previous then unique[#unique + 1], previous = channel, channel end
        end
        local actorSet = {}
        for _, actorKey in ipairs(actors) do
            local claimed, claimError = locks.claim(actorKey, unique, session.id, id)
            if not claimed then locks.release(session.id, id); return nil, claimError end
            actorSet[actorKey] = true
        end
        local execution = {
            id = id, sessionId = session.id, intentKey = resolved.intent.key,
            graphKey = resolved.graph.key, graph = resolved.graph,
            ownerResource = resolved.bundle.ownerResource,
            ownerEpoch = resolved.bundle.ownerEpoch,
            bundleRevision = resolved.bundle.revision,
            target = Validation.copy(lease.target), traceId = context.traceId,
            leaseId = lease.id,
            startedAt = now(), deadlineAt = now() + resolved.graph.timeoutMs,
            participants = participants(session), steps = 0, sequence = 0,
            actors = actorSet, lockChannels = unique,
            pendingAcks = {}, commits = {}, commitClaims = {}, commitsInFlight = 0,
            committed = false, leaseReleased = false,
            cancelled = false, cleaned = false, paused = false, state = 'CREATED',
        }
        executions[id], executionCount = execution, executionCount + 1
        local attached, attachError = sessions.setExecution(session.id, id)
        if not attached then executions[id], executionCount = nil, executionCount - 1;
            locks.release(session.id, id); return nil, attachError end
        Foundation.protect(observability.increment, 'graph_started_total', {}, 1)
        Foundation.protect(observability.trace, execution.traceId, {
            phase = 'graph_started', execution = execution.id,
            graph = execution.graphKey,
        })
        spawn(function()
            execution.state = 'RUNNING'
            local ok, value = Foundation.protect(
                runNode, execution, execution.graph.entry, nil, 0, false)
            if ok and value == COMPLETE_SIGNAL then cleanup(execution, 'COMPLETED', nil)
            elseif ok then cleanup(execution, 'FAILED', failure('INTERACT_GRAPH_INVALID',
                'The interaction graph ended without an explicit complete terminal.', false))
            elseif type(value) == 'table' and value.code == 'INTERACT_TIMEOUT' then
                cleanup(execution, 'TIMED_OUT', value)
            elseif execution.cancelled and not execution.committed then
                cleanup(execution, 'ABORTED', value)
            else cleanup(execution, 'FAILED', value) end
        end)
        return { executionId = id, state = 'RUNNING' }, nil
    end

    function runtime.setLeaseReleaser(handler)
        if not Validation.isCallable(handler) then
            return Validation.failure('INTERACT_UNAVAILABLE',
                'The interaction lease releaser is unavailable.', true)
        end
        leaseReleaser = handler
        return true, nil
    end

    function runtime.participantLeft(sessionId, actorKey, policy, replacementLeaseId, reason)
        local session = sessions.get(sessionId)
        local execution = session and session.executionId and executions[session.executionId]
        if not execution or not Validation.actorKey(actorKey) then return false end
        locks.release(sessionId, execution.id, actorKey)
        execution.actors[actorKey] = nil
        execution.participants = participants(session)
        if replacementLeaseId ~= nil then execution.leaseId = replacementLeaseId end
        if policy == 'ABORT' then
            execution.cancelled = true
            execution.cancelReason = reason or 'PARTICIPANT_LOST'
            execution.state = 'ABORTING'
        elseif policy == 'REPLACE' then
            execution.paused = true
            execution.state = 'PREPARING'
        elseif #execution.participants == 0 then
            execution.cancelled = true
            execution.cancelReason = reason or 'PARTICIPANT_LOST'
            execution.state = 'ABORTING'
        end
        return true
    end

    function runtime.participantJoined(sessionId, actorKey)
        local session = sessions.get(sessionId)
        local execution = session and session.executionId and executions[session.executionId]
        if not execution or execution.cleaned or execution.cancelled
            or not Validation.actorKey(actorKey) then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction graph execution is unavailable.')
        end
        if not execution.actors[actorKey] then
            local acquired, acquireError = locks.claim(actorKey,
                execution.lockChannels, session.id, execution.id)
            if not acquired then return nil, acquireError end
            execution.actors[actorKey] = true
        end
        execution.participants = participants(session)
        return { executionId = execution.id, state = execution.state,
            participants = #execution.participants }, nil
    end

    function runtime.resume(session, resolved, lease)
        local execution = session and session.executionId and executions[session.executionId]
        if not execution or execution.ownerResource ~= resolved.bundle.ownerResource
            or execution.ownerEpoch ~= resolved.bundle.ownerEpoch
            or execution.bundleRevision ~= resolved.bundle.revision then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction graph execution is unavailable.')
        end
        local claimed = {}
        for _, actorKey in ipairs(actorKeys(session)) do
            if not execution.actors[actorKey] then
                local acquired, acquireError = locks.claim(actorKey,
                    execution.lockChannels, session.id, execution.id)
                if not acquired then
                    for _, rollbackKey in ipairs(claimed) do
                        locks.release(session.id, execution.id, rollbackKey)
                    end
                    return nil, acquireError
                end
                claimed[#claimed + 1] = actorKey
            end
        end
        local resumed, resumeError = sessions.resumeExecution(session.id, execution.id)
        if not resumed then
            for _, rollbackKey in ipairs(claimed) do
                locks.release(session.id, execution.id, rollbackKey)
            end
            return nil, resumeError
        end
        for _, actorKey in ipairs(claimed) do execution.actors[actorKey] = true end
        execution.participants = participants(session)
        execution.leaseId = lease.id
        execution.paused = false
        execution.state = 'RUNNING'
        return { executionId = execution.id, state = 'RUNNING', resumed = true }, nil
    end

    function runtime.ack(request, context)
        local execution = executions[request.executionId]
        if not execution or execution.sessionId ~= request.sessionId then
            return Validation.failure('INTERACT_SESSION_NOT_FOUND',
                'The interaction graph execution is unavailable.')
        end
        local actorKey = tostring(context.source) .. ':' .. tostring(context.sourceGeneration)
        local member = false
        for _, participant in ipairs(execution.participants) do
            if participant.source == context.source
                and participant.sourceGeneration == context.sourceGeneration then member = true; break end
        end
        if not member then return Validation.failure('INTERACT_LEASE_STALE',
            'The graph acknowledgement actor is stale.') end
        local pending = execution.pendingAcks[request.nodeKey]
        if not pending or request.sequence ~= pending.sequence then
            return Validation.failure('INTERACT_GRAPH_INVALID',
                'The graph acknowledgement is stale.')
        end
        local duplicate = pending.results[actorKey] ~= nil
        if not duplicate then pending.results[actorKey] = request.result end
        return { accepted = true, duplicate = duplicate }, nil
    end

    function runtime.cancel(sessionId, reason)
        local session = sessions.get(sessionId)
        local execution = session and session.executionId and executions[session.executionId]
        if not execution then return false end
        execution.cancelled = true
        execution.cancelReason = reason
        execution.state = 'ABORTING'
        return true
    end

    function runtime.cancelOwner(owner, epoch, reason)
        local count = 0
        for _, execution in pairs(executions) do
            if execution.ownerResource == owner and (epoch == nil or execution.ownerEpoch == epoch) then
                execution.cancelled, execution.cancelReason = true, reason or 'OWNER_STOPPED'
                execution.state = 'ABORTING'
                count = count + 1
            end
        end
        return count
    end

    function runtime.list(cursor, limit)
        local values = {}
        for _, execution in pairs(executions) do
            local roleCounts, participantCount, participantRoles = {}, 0, {}
            for _, participant in ipairs(execution.participants or {}) do
                participantCount = participantCount + 1
                roleCounts[participant.role] = (roleCounts[participant.role] or 0) + 1
            end
            local roleKeys = {}
            for role in pairs(roleCounts) do roleKeys[#roleKeys + 1] = role end
            table.sort(roleKeys)
            for _, role in ipairs(roleKeys) do
                participantRoles[#participantRoles + 1] = {
                    role = role, count = roleCounts[role],
                }
            end
            values[#values + 1] = { executionId = execution.id,
                sessionId = execution.sessionId, graph = execution.graphKey,
                intent = execution.intentKey, currentNode = execution.currentNode,
                committed = execution.committed, state = execution.state,
                startedAt = execution.startedAt,
                deadlineAt = execution.deadlineAt,
                elapsedMs = math.max(0, math.floor(now() - execution.startedAt)),
                participantCount = participantCount,
                participantRoles = participantRoles,
                lockChannels = Validation.copy(execution.lockChannels) or {},
                leaseReleased = execution.leaseReleased == true }
        end
        table.sort(values, function(left, right) return left.executionId < right.executionId end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + size - 1) do items[#items + 1] = values[index] end
        local hasMore = start + #items - 1 < #values
        return { items = items, nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end

    function runtime.snapshot() return { active = executionCount } end
    return runtime
end
