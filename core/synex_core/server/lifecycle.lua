local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.lifecycle = function(deps)
    local foundation = assert(deps.foundation, 'lifecycle requires foundation')
    local platform = assert(deps.platform, 'lifecycle requires platform')
    local metrics = foundation.metrics
    local logger = foundation.logger

    local allowed = {
        CREATED = { CONFIGURING = true, FAILED = true, STOPPING = true },
        CONFIGURING = { DATABASE_CONNECTING = true, FAILED = true, STOPPING = true },
        DATABASE_CONNECTING = { MIGRATING = true, FAILED = true, STOPPING = true },
        MIGRATING = { DISCOVERING_RESOURCES = true, FAILED = true, STOPPING = true },
        DISCOVERING_RESOURCES = { VALIDATING_CONTRACTS = true, FAILED = true, STOPPING = true },
        VALIDATING_CONTRACTS = { VALIDATING_CAPABILITIES = true, FAILED = true, STOPPING = true },
        VALIDATING_CAPABILITIES = { STARTING_SERVICES = true, FAILED = true, STOPPING = true },
        STARTING_SERVICES = { READY = true, DEGRADED = true, FAILED = true, STOPPING = true },
        READY = { DEGRADED = true, UNHEALTHY = true, QUIESCING = true, FAILED = true, STOPPING = true },
        DEGRADED = { READY = true, UNHEALTHY = true, QUIESCING = true, FAILED = true, STOPPING = true },
        UNHEALTHY = { READY = true, DEGRADED = true, QUIESCING = true, FAILED = true, STOPPING = true },
        QUIESCING = { FAILED = true, STOPPING = true },
        FAILED = { STOPPING = true },
        STOPPING = { STOPPED = true },
        STOPPED = {}
    }

    local state = 'CREATED'
    local revision = 0
    local transitions = {}
    local maximumRecentTransitions = 64
    local healthReasons = {}
    local criticalFoundationsValidated = false
    local healthObserver = nil
    local stateMachine = {}

    local function notifyHealthObserver()
        if not healthObserver then return true end
        local invoked, value, observerError = foundation.safeCall(healthObserver)
        if invoked and value ~= nil and observerError == nil then return true end
        local failure = invoked and observerError or value
        logger:error('core health observer failed', {
            code = type(failure) == 'table' and failure.code or 'HEALTH_OBSERVER_FAILED'
        })
        return false
    end

    function stateMachine:get() return state, revision end
    function stateMachine:isOperational() return state == 'READY' or state == 'DEGRADED' end
    function stateMachine:setHealthObserver(observer)
        if type(observer) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Core health observer must be a function.')
        end
        healthObserver = observer
        if not notifyHealthObserver() then
            healthObserver = nil
            return nil, foundation.error('HEALTH_OBSERVER_FAILED', 'Core health observer initialization failed.')
        end
        return true, nil
    end
    function stateMachine:setCriticalFoundationsValidated(validated)
        criticalFoundationsValidated = validated == true
        notifyHealthObserver()
    end
    function stateMachine:canAdmitPlayers()
        return state == 'READY' and criticalFoundationsValidated and next(healthReasons) == nil
    end
    function stateMachine:healthStatus()
        if state == 'UNHEALTHY' or state == 'FAILED' then return 'UNHEALTHY' end
        if state == 'DEGRADED' or next(healthReasons) ~= nil
            or (state == 'READY' and not self:canAdmitPlayers()) then
            return 'DEGRADED'
        end
        if state == 'READY' then return 'HEALTHY' end
        return 'UNKNOWN'
    end
    function stateMachine:transition(target, reason, expectedRevision)
        if expectedRevision ~= nil and expectedRevision ~= revision then
            return nil, foundation.error('STALE_REVISION', 'The lifecycle revision changed.')
        end
        if not (allowed[state] and allowed[state][target]) then
            return nil, foundation.error('INVALID_STATE_TRANSITION', ('Cannot transition from %s to %s.'):format(state, target))
        end
        local previous = state
        state = target
        revision = revision + 1
        transitions[#transitions + 1] = {
            from = previous, to = target, reason = reason, revision = revision, at = foundation.utcIso()
        }
        if #transitions > maximumRecentTransitions then table.remove(transitions, 1) end
        metrics:increment('synex_lifecycle_transitions_total', { from = previous, to = target })
        logger:info('core lifecycle transition', { from = previous, to = target, reason = reason, revision = revision })
        notifyHealthObserver()
        return revision, nil
    end
    function stateMachine:setHealth(component, status, reason)
        if status == 'HEALTHY' then healthReasons[component] = nil
        else healthReasons[component] = { status = status, reason = tostring(reason or 'unspecified') } end
        notifyHealthObserver()
    end
    function stateMachine:snapshot()
        return {
            state = state,
            revision = revision,
            operational = self:isOperational(),
            playerAdmission = self:canAdmitPlayers(),
            reasons = foundation.copy(healthReasons),
            recentTransitions = foundation.copy(transitions)
        }
    end

    local schedules = {}
    local scheduleCount = 0
    local scheduleCounts = {}
    local deadlineHeap = {}
    local timerGeneration = nil
    local timerDueAt = nil
    local nextTimerGeneration = 0
    local pendingTimerCount = 0
    local runningHandlerCount = 0
    local detachedRunningHandlerCount = 0
    local scheduleSequence = 0
    local function boundedCapacity(value, fallback, maximum)
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < 1 or value > maximum then return fallback end
        return value
    end
    local maximumSchedules = boundedCapacity(deps.maximumSchedules, 4096, 16384)
    local maximumSchedulesPerOwner = boundedCapacity(
        deps.maximumSchedulesPerOwner, 256, 2048)
    local maximumRunningHandlers = boundedCapacity(
        deps.maximumRunningHandlers, 64, 1024)
    local maximumPendingTimers = boundedCapacity(
        deps.maximumPendingTimers, 64, 256)
    local scheduler = {}
    local schedulerSuspended = {}
    local pump

    local function deadlineLess(left, right)
        if left.dueAt == right.dueAt then return left.sequence < right.sequence end
        return left.dueAt < right.dueAt
    end

    local function heapSwap(leftIndex, rightIndex)
        local left, right = deadlineHeap[leftIndex], deadlineHeap[rightIndex]
        deadlineHeap[leftIndex], deadlineHeap[rightIndex] = right, left
        right.heapIndex, left.heapIndex = leftIndex, rightIndex
    end

    local function heapPush(entry)
        local index = #deadlineHeap + 1
        deadlineHeap[index] = entry
        entry.heapIndex = index
        while index > 1 do
            local parent = math.floor(index / 2)
            if not deadlineLess(deadlineHeap[index], deadlineHeap[parent]) then break end
            heapSwap(index, parent)
            index = parent
        end
    end

    local function heapRemove(entry)
        local index = entry.heapIndex
        if index == nil or deadlineHeap[index] ~= entry then return false end
        local last = table.remove(deadlineHeap)
        entry.heapIndex = nil
        if index > #deadlineHeap then return true end
        deadlineHeap[index] = last
        last.heapIndex = index
        local parent = math.floor(index / 2)
        if index > 1 and deadlineLess(last, deadlineHeap[parent]) then
            while index > 1 do
                parent = math.floor(index / 2)
                if not deadlineLess(deadlineHeap[index], deadlineHeap[parent]) then break end
                heapSwap(index, parent)
                index = parent
            end
            return true
        end
        while true do
            local left = index * 2
            if left > #deadlineHeap then break end
            local right = left + 1
            local smallest = left
            if right <= #deadlineHeap
                and deadlineLess(deadlineHeap[right], deadlineHeap[left]) then
                smallest = right
            end
            if not deadlineLess(deadlineHeap[smallest], deadlineHeap[index]) then break end
            heapSwap(index, smallest)
            index = smallest
        end
        return true
    end

    local function setEntryRunning(entry, running)
        if entry.running == running then return end
        entry.running = running
        if running then
            runningHandlerCount = runningHandlerCount + 1
            return
        end
        runningHandlerCount = math.max(0, runningHandlerCount - 1)
        if entry.detached then
            entry.detached = false
            detachedRunningHandlerCount = math.max(0, detachedRunningHandlerCount - 1)
        end
    end

    local function cancelInvocation(entry, reason)
        local invocation = entry.invocation
        if not invocation or invocation.cancelled then return end
        local boundedReason = tostring(reason or 'schedule cancelled')
        if #boundedReason > 256 then boundedReason = boundedReason:sub(1, 256) end
        invocation.cancelled = true
        invocation.reason = boundedReason
    end

    local function removeSchedule(token, entry, releaseOwner)
        if schedules[token] ~= entry then return false end
        if entry.heapIndex ~= nil then heapRemove(entry) end
        schedules[token] = nil
        scheduleCount = math.max(0, scheduleCount - 1)
        scheduleCounts[entry.owner] = math.max(0,
            (scheduleCounts[entry.owner] or 1) - 1)
        if scheduleCounts[entry.owner] == 0 then scheduleCounts[entry.owner] = nil end
        if entry.running and not entry.detached then
            entry.detached = true
            detachedRunningHandlerCount = detachedRunningHandlerCount + 1
        end
        if releaseOwner then deps.owners:release(entry.owner, 'schedule', token) end
        return true
    end

    local function armPump()
        local earliest = deadlineHeap[1]
        if earliest == nil then return true, nil end
        local now = foundation.monotonicMs()
        if earliest.dueAt <= now and runningHandlerCount >= maximumRunningHandlers then
            return true, nil
        end
        local desiredDueAt = math.max(now + 1, earliest.dueAt)
        if timerGeneration ~= nil and timerDueAt <= desiredDueAt then return true, nil end
        if pendingTimerCount >= maximumPendingTimers then
            return nil, foundation.error('SCHEDULER_TIMER_LIMIT',
                'The scheduler cannot safely arm another native timer.', { retryable = true })
        end
        local wakeAfter = math.max(1, math.ceil(desiredDueAt - now))
        nextTimerGeneration = nextTimerGeneration + 1
        local generation = nextTimerGeneration
        local previousGeneration, previousDueAt = timerGeneration, timerDueAt
        timerGeneration = generation
        timerDueAt = now + wakeAfter
        pendingTimerCount = pendingTimerCount + 1
        local armed, armFailure = foundation.safeCall(
            platform.setTimeout, wakeAfter, function()
                pendingTimerCount = math.max(0, pendingTimerCount - 1)
                if timerGeneration ~= generation then return end
                timerGeneration = nil
                timerDueAt = nil
                pump()
            end)
        if not armed then
            pendingTimerCount = math.max(0, pendingTimerCount - 1)
            if timerGeneration == generation then
                timerGeneration = previousGeneration
                timerDueAt = previousDueAt
            end
            return nil, foundation.error('SCHEDULER_ARM_FAILED',
                'The scheduler timer could not be armed.', {
                    retryable = true,
                    details = {
                        cause = foundation.failureCode(armFailure, 'SCHEDULER_ARM_FAILED')
                    }
                })
        end
        return true, nil
    end

    local function runEntry(token, entry)
        if schedules[token] ~= entry then return end
        if entry.cancelled or not deps.owners:isCurrent(entry.owner, entry.epoch) then
            removeSchedule(token, entry, true)
            return false
        end
        local invocation = { cancelled = false, reason = nil }
        entry.invocation = invocation
        local cancellationMethods = {
            isCancelled = function() return invocation.cancelled end,
            checkpoint = function()
                if not invocation.cancelled then return true, nil end
                return nil, foundation.error('SCHEDULE_CANCELLED',
                    'The scheduled handler was cancelled.', {
                        retryable = true,
                        details = { reason = invocation.reason }
                    })
            end
        }
        local cancellation = setmetatable({}, {
            __index = function(_, key)
                if key == 'cancelled' then return invocation.cancelled end
                if key == 'reason' then return invocation.reason end
                return cancellationMethods[key]
            end,
            __newindex = function()
                error('attempt to mutate a Synex scheduler cancellation context', 2)
            end,
            __metatable = false
        })
        local operationToken = deps.owners:beginOperation(
            entry.owner, entry.epoch, function(reason) cancelInvocation(entry, reason) end)
        if not operationToken then
            entry.invocation = nil
            removeSchedule(token, entry, true)
            return false
        end
        local started = foundation.monotonicMs()
        local ok, result, handlerError = foundation.safeCall(entry.handler, token, cancellation)
        deps.owners:finishOperation(entry.owner, entry.epoch, operationToken)
        if entry.invocation == invocation then entry.invocation = nil end
        entry.lastRun = foundation.utcIso()
        entry.durationMs = math.max(0, foundation.monotonicMs() - started)
        entry.runs = entry.runs + 1
        if ok and handlerError == nil and result == schedulerSuspended then
            if entry.consecutiveFailures == 0 then
                entry.health = 'DEGRADED'
                entry.lastError = 'SCHEDULE_SUSPENDED'
            else
                entry.health = entry.consecutiveFailures >= 3 and 'UNHEALTHY' or 'DEGRADED'
            end
        elseif not ok or handlerError ~= nil or result == false then
            local failure = not ok and result or handlerError or 'handler returned false'
            entry.consecutiveFailures = entry.consecutiveFailures + 1
            entry.health = entry.consecutiveFailures >= 3 and 'UNHEALTHY' or 'DEGRADED'
            entry.lastError = foundation.failureCode(failure,
                not ok and 'SCHEDULE_HANDLER_EXCEPTION'
                    or (result == false and 'SCHEDULE_HANDLER_REJECTED'
                        or 'SCHEDULE_HANDLER_FAILED'))
            logger:error('scheduled handler failed', {
                owner = entry.owner,
                worker = entry.name,
                token = token,
                code = entry.lastError,
                consecutiveFailures = entry.consecutiveFailures
            })
        else
            entry.consecutiveFailures = 0
            entry.health = 'HEALTHY'
            entry.lastError = nil
        end
        if entry.recurring and not entry.cancelled and not invocation.cancelled
            and deps.owners:isCurrent(entry.owner, entry.epoch)
            and schedules[token] == entry then
            entry.dueAt = foundation.monotonicMs() + entry.delay
            return true
        else
            removeSchedule(token, entry, true)
            return false
        end
    end

    local function failStrandedSchedules(armError)
        local stranded = {}
        for token, entry in pairs(schedules) do
            stranded[#stranded + 1] = { token = token, entry = entry }
        end
        for _, item in ipairs(stranded) do
            item.entry.cancelled = true
            cancelInvocation(item.entry, 'scheduler timer failure')
            removeSchedule(item.token, item.entry, true)
        end
        logger:error('scheduler pump could not be armed', {
            code = foundation.failureCode(armError, 'SCHEDULER_ARM_FAILED'),
            stranded = #stranded
        })
    end

    local function dispatchEntry(token, entry)
        local function execute()
            local executed, rescheduleOrFailure = foundation.safeCall(runEntry, token, entry)
            setEntryRunning(entry, false)
            if not executed then
                removeSchedule(token, entry, true)
                logger:error('scheduled handler dispatch failed', {
                    owner = entry.owner,
                    worker = entry.name,
                    token = token,
                    code = foundation.failureCode(
                        rescheduleOrFailure, 'SCHEDULER_DISPATCH_FAILED')
                })
            elseif rescheduleOrFailure == true and schedules[token] == entry
                and not entry.cancelled
                and deps.owners:isCurrent(entry.owner, entry.epoch) then
                heapPush(entry)
            end
            local armed, armError = armPump()
            if not armed then failStrandedSchedules(armError) end
        end
        if type(platform.createThread) == 'function' then
            local launched, launchFailure = foundation.safeCall(platform.createThread, execute)
            if launched then return true end
            setEntryRunning(entry, false)
            removeSchedule(token, entry, true)
            logger:error('scheduled handler thread could not be created', {
                owner = entry.owner,
                worker = entry.name,
                token = token,
                code = foundation.failureCode(launchFailure, 'SCHEDULER_THREAD_FAILED')
            })
            local armed, armError = armPump()
            if not armed then failStrandedSchedules(armError) end
            return false
        end
        execute()
        return true
    end

    pump = function()
        local now = foundation.monotonicMs()
        local due = {}
        while runningHandlerCount < maximumRunningHandlers do
            local entry = deadlineHeap[1]
            if entry == nil or entry.dueAt > now then break end
            local token = entry.token
            if entry.cancelled or not deps.owners:isCurrent(entry.owner, entry.epoch) then
                removeSchedule(token, entry, true)
            else
                heapRemove(entry)
                setEntryRunning(entry, true)
                due[#due + 1] = { token = token, entry = entry }
            end
        end
        local armed, armError = armPump()
        if not armed then
            failStrandedSchedules(armError)
            return
        end
        for _, item in ipairs(due) do dispatchEntry(item.token, item.entry) end
    end

    local function schedule(owner, epoch, delay, recurring, handler, options)
        if type(delay) ~= 'number' or math.type(delay) ~= 'integer'
            or delay < 0 or delay > 86400000 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Schedule delay is outside the supported range.')
        end
        if not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_ARGUMENT', 'Schedule handler is required.')
        end
        if options ~= nil and (type(options) ~= 'table' or getmetatable(options) ~= nil) then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Schedule options must be a plain object.')
        end
        options = options or {}
        for key in next, options do
            if key ~= 'name' then
                return nil, foundation.error('INVALID_ARGUMENT',
                    'Schedule options contain an unsupported property.')
            end
        end
        if options.name ~= nil and (type(options.name) ~= 'string'
            or #options.name < 3 or #options.name > 96
            or not options.name:match('^[a-z][a-z0-9_.%-]*$')) then
            return nil, foundation.error('INVALID_ARGUMENT', 'Worker name is invalid.')
        end
        if scheduleCount >= maximumSchedules
            or (scheduleCounts[owner] or 0) >= maximumSchedulesPerOwner then
            return nil, foundation.error('SCHEDULER_LIMIT',
                'The resource has reached its active schedule limit.')
        end
        local token = foundation.nextId('schedule')
        scheduleSequence = scheduleSequence + 1
        local entry = {
            token = token,
            sequence = scheduleSequence,
            owner = owner,
            epoch = epoch,
            cancelled = false,
            running = false,
            detached = false,
            invocation = nil,
            heapIndex = nil,
            delay = delay,
            dueAt = foundation.monotonicMs() + delay,
            recurring = recurring,
            handler = handler,
            name = options.name or token,
            health = recurring and 'STARTING' or 'SCHEDULED',
            lastRun = nil,
            durationMs = nil,
            lastError = nil,
            runs = 0,
            consecutiveFailures = 0
        }
        schedules[token] = entry
        heapPush(entry)
        scheduleCount = scheduleCount + 1
        scheduleCounts[owner] = (scheduleCounts[owner] or 0) + 1
        local _, trackError = deps.owners:track(owner, epoch, 'schedule', token, function()
            entry.cancelled = true
            cancelInvocation(entry, 'resource owner purged')
            removeSchedule(token, entry, false)
        end)
        if trackError then
            entry.cancelled = true
            removeSchedule(token, entry, false)
            return nil, trackError
        end
        local armed, armError = armPump()
        if not armed then
            entry.cancelled = true
            removeSchedule(token, entry, true)
            return nil, armError
        end
        return token, nil
    end

    function scheduler:after(owner, epoch, delay, handler, options)
        return schedule(owner, epoch, delay, false, handler, options)
    end
    function scheduler:every(owner, epoch, delay, handler, options)
        if type(delay) ~= 'number' or math.type(delay) ~= 'integer' or delay < 50 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Recurring schedules must use an integer interval of at least 50 ms.')
        end
        return schedule(owner, epoch, delay, true, handler, options)
    end
    function scheduler:suspended()
        return schedulerSuspended
    end
    function scheduler:cancel(owner, token)
        local entry = schedules[token]
        if not entry or entry.owner ~= owner then return false end
        entry.cancelled = true
        cancelInvocation(entry, 'schedule cancelled')
        removeSchedule(token, entry, true)
        return true
    end
    function scheduler:count() return scheduleCount end
    function scheduler:capacity()
        return {
            schedules = scheduleCount,
            maximumSchedules = maximumSchedules,
            queuedSchedules = #deadlineHeap,
            runningHandlers = runningHandlerCount,
            detachedRunningHandlers = detachedRunningHandlerCount,
            maximumRunningHandlers = maximumRunningHandlers,
            pendingTimers = pendingTimerCount,
            maximumPendingTimers = maximumPendingTimers
        }
    end
    function scheduler:snapshot()
        local result = {}
        for token, entry in pairs(schedules) do
            result[#result + 1] = {
                token = token,
                name = entry.name,
                resource = entry.owner,
                intervalMs = entry.delay,
                recurring = entry.recurring,
                running = entry.running,
                health = entry.health,
                lastRun = entry.lastRun,
                durationMs = entry.durationMs,
                lastError = entry.lastError,
                runs = entry.runs
            }
        end
        table.sort(result, function(left, right)
            if left.resource == right.resource then return left.name < right.name end
            return left.resource < right.resource
        end)
        return result
    end

    local reload = {}
    local function boundedInteger(value, defaultValue, minimum, maximum)
        if value == nil then return defaultValue end
        if type(value) ~= 'number' or math.type(value) ~= 'integer' or value < minimum or value > maximum then
            return nil
        end
        return value
    end

    function reload:quiesce(owner, epoch, options)
        options = type(options) == 'table' and options or {}
        local timeoutMs = boundedInteger(options.timeoutMs, 250, 0, 10000)
        local pollMs = boundedInteger(options.pollMs, 10, 1, 100)
        if timeoutMs == nil or pollMs == nil then
            return nil, foundation.error('INVALID_ARGUMENT', 'Drain timeout or poll interval is outside the supported range.')
        end
        if options.capture ~= nil and type(options.capture) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Snapshot capture must be a function.')
        end
        local quiesce, quiesceError = deps.owners:beginQuiesce(owner, epoch, options.reason)
        if not quiesce then return nil, quiesceError end

        local startedAt = foundation.monotonicMs()
        local maximumPolls = timeoutMs == 0 and 0 or math.ceil(timeoutMs / pollMs)
        local polls = 0
        local drainError = nil
        while deps.owners:pendingCount(owner, epoch) > 0
            and polls < maximumPolls
            and foundation.monotonicMs() - startedAt < timeoutMs do
            polls = polls + 1
            local elapsed = foundation.monotonicMs() - startedAt
            local delay = math.min(pollMs, math.max(0, timeoutMs - elapsed))
            local waited, waitError = foundation.safeCall(platform.wait, delay)
            if not waited then
                drainError = foundation.error('DRAIN_WAIT_FAILED', 'The runtime could not wait for pending work.', {
                    details = { cause = foundation.failureCode(waitError, 'DRAIN_WAIT_EXCEPTION') }
                })
                break
            end
        end

        local remaining = deps.owners:pendingCount(owner, epoch)
        local timedOut = remaining > 0
        local abortReport = { aborted = 0, errors = {} }
        if remaining > 0 then
            abortReport = deps.owners:abortPending(owner, epoch, options.reason or 'resource quiesce timeout')
        end

        local snapshot = nil
        local snapshotError = nil
        if options.capture then
            local captured, value, captureError = foundation.safeCall(options.capture, owner, epoch)
            if not captured then
                snapshotError = foundation.error('SNAPSHOT_CAPTURE_FAILED', 'The reconstructable state snapshot failed.', {
                    details = { cause = foundation.failureCode(value, 'SNAPSHOT_CAPTURE_EXCEPTION') }
                })
            elseif value == nil then
                if type(captureError) == 'table' and type(captureError.code) == 'string' then
                    snapshotError = foundation.error(
                        foundation.failureCode(captureError, 'SNAPSHOT_CAPTURE_FAILED'),
                        'The reconstructable state snapshot failed.')
                else
                    snapshotError = foundation.error('SNAPSHOT_CAPTURE_FAILED', 'The reconstructable state snapshot failed.', {
                        details = captureError ~= nil and {
                            cause = foundation.failureCode(captureError, 'SNAPSHOT_CAPTURE_FAILED')
                        } or nil
                    })
                end
            else
                snapshot = value
            end
        end

        local cleanup = deps.owners:purge(owner, epoch, options.reason or 'resource quiesced')
        local report = {
            owner = owner,
            epoch = epoch,
            drained = not timedOut and drainError == nil,
            timedOut = timedOut,
            pendingAtStart = quiesce.pending,
            aborted = abortReport.aborted or 0,
            abortErrors = foundation.copy(abortReport.errors or {}),
            durationMs = math.max(0, foundation.monotonicMs() - startedAt),
            snapshot = snapshot,
            snapshotError = snapshotError,
            drainError = drainError,
            cleanup = cleanup
        }
        metrics:increment('synex_owner_quiesce_total', {
            owner = owner,
            timedOut = report.timedOut,
            snapshot = snapshot ~= nil
        })
        return report, nil
    end

    function reload:restore(owner, epoch, snapshot, handler)
        if type(handler) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Snapshot restore requires a handler.')
        end
        if not deps.owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The restore target is not the current owner epoch.')
        end
        local invocation = { cancelled = false, reason = nil }
        local operationToken, operationError = deps.owners:beginOperation(owner, epoch, function(reason)
            invocation.cancelled = true
            invocation.reason = tostring(reason or 'owner quiesced')
        end)
        if not operationToken then return nil, operationError end
        local restored, value, restoreError = foundation.safeCall(handler, owner, epoch, snapshot)
        deps.owners:finishOperation(owner, epoch, operationToken)
        if invocation.cancelled then
            return nil, foundation.error('REQUEST_ABORTED', 'The state handoff restore was aborted while its owner was quiescing.', {
                retryable = true,
                details = { reason = invocation.reason }
            })
        end
        if not restored then
            return nil, foundation.error('SNAPSHOT_RESTORE_FAILED', 'The reconstructable state restore raised an error.', {
                details = { cause = foundation.failureCode(value, 'SNAPSHOT_RESTORE_EXCEPTION') }
            })
        end
        if value == nil then
            if type(restoreError) == 'table' and type(restoreError.code) == 'string' then
                return nil, foundation.error(
                    foundation.failureCode(restoreError, 'SNAPSHOT_RESTORE_FAILED'),
                    'The reconstructable state restore failed.')
            end
            return nil, foundation.error('SNAPSHOT_RESTORE_FAILED', 'The reconstructable state restore failed.', {
                details = restoreError ~= nil and {
                    cause = foundation.failureCode(restoreError, 'SNAPSHOT_RESTORE_FAILED')
                } or nil
            })
        end
        return value, nil
    end

    local graph = { providers = {}, providerHealth = {}, consumers = {} }
    local dependencies = {}
    function dependencies:require(consumer, service, range, optional, critical)
        graph.consumers[consumer] = graph.consumers[consumer] or {}
        graph.consumers[consumer][service] = {
            range = range, optional = optional == true, critical = critical == true
        }
    end
    function dependencies:provide(provider, service, version)
        local parsed = foundation.semver(version)
        if not parsed then
            return nil, foundation.error('INVALID_SERVICE_VERSION',
                'Dependency providers require a semantic service version.')
        end
        local major = tostring(parsed.major)
        graph.providers[service] = graph.providers[service] or {}
        graph.providers[service][provider] = graph.providers[service][provider] or {}
        graph.providers[service][provider][major] = version
        graph.providerHealth[service] = graph.providerHealth[service] or {}
        graph.providerHealth[service][provider] = graph.providerHealth[service][provider] or {}
        graph.providerHealth[service][provider][major] = { health = 'HEALTHY', circuit = 'CLOSED' }
        return true, nil
    end
    function dependencies:setProviderHealth(provider, service, version, health, circuit)
        local parsed = foundation.semver(version)
        if not parsed then
            return nil, foundation.error('INVALID_SERVICE_VERSION',
                'Provider health requires a semantic service version.')
        end
        local major = tostring(parsed.major)
        local providers = graph.providers[service]
        if not (providers and providers[provider] and providers[provider][major] == version) then
            return nil, foundation.error('PROVIDER_NOT_REGISTERED', 'Provider health requires a registered service provider.')
        end
        if health ~= 'HEALTHY' and health ~= 'DEGRADED' and health ~= 'UNHEALTHY' then
            return nil, foundation.error('INVALID_PROVIDER_HEALTH', 'Provider health is invalid.')
        end
        if circuit ~= 'CLOSED' and circuit ~= 'HALF_OPEN' and circuit ~= 'OPEN' then
            return nil, foundation.error('INVALID_PROVIDER_CIRCUIT', 'Provider circuit state is invalid.')
        end
        graph.providerHealth[service] = graph.providerHealth[service] or {}
        graph.providerHealth[service][provider] = graph.providerHealth[service][provider] or {}
        graph.providerHealth[service][provider][major] = { health = health, circuit = circuit }
        return true, nil
    end
    function dependencies:removeProvider(provider, selectedService, selectedVersion)
        local selectedMajor = nil
        if selectedVersion ~= nil then
            local parsed = foundation.semver(selectedVersion)
            if not parsed then return false end
            selectedMajor = tostring(parsed.major)
        end
        local removed = false
        for service, providers in pairs(graph.providers) do
            if selectedService == nil or service == selectedService then
                local versions = providers[provider]
                if versions then
                    if selectedMajor then
                        if versions[selectedMajor] == selectedVersion then
                            versions[selectedMajor] = nil
                            removed = true
                            if graph.providerHealth[service]
                                and graph.providerHealth[service][provider] then
                                graph.providerHealth[service][provider][selectedMajor] = nil
                            end
                        end
                    else
                        providers[provider] = nil
                        removed = true
                        if graph.providerHealth[service] then
                            graph.providerHealth[service][provider] = nil
                        end
                    end
                    if providers[provider] and next(providers[provider]) == nil then
                        providers[provider] = nil
                    end
                    if graph.providerHealth[service]
                        and graph.providerHealth[service][provider]
                        and next(graph.providerHealth[service][provider]) == nil then
                        graph.providerHealth[service][provider] = nil
                    end
                end
                if next(providers) == nil then graph.providers[service] = nil end
                if graph.providerHealth[service] and next(graph.providerHealth[service]) == nil then
                    graph.providerHealth[service] = nil
                end
            end
        end
        return removed
    end
    function dependencies:removeConsumer(consumer)
        local registered = graph.consumers[consumer] ~= nil
        graph.consumers[consumer] = nil
        return registered
    end
    function dependencies:validate(inactiveResource)
        local findings = {}
        for consumer, requirements in pairs(graph.consumers) do
            local state = type(platform.resourceState) == 'function' and platform.resourceState(consumer) or 'started'
            local consumerActive = consumer ~= inactiveResource and (state == 'started' or state == 'starting')
            for service, requirement in pairs(consumerActive and requirements or {}) do
                local compatible = false
                for provider, versions in pairs(graph.providers[service] or {}) do
                    local providerState = type(platform.resourceState) == 'function'
                        and platform.resourceState(provider) or 'started'
                    for major, version in pairs(versions) do
                        local runtimeHealth = graph.providerHealth[service]
                            and graph.providerHealth[service][provider]
                            and graph.providerHealth[service][provider][major] or nil
                        local providerHealthy = runtimeHealth == nil
                            or (runtimeHealth.health ~= 'UNHEALTHY' and runtimeHealth.circuit ~= 'OPEN')
                        if provider ~= inactiveResource
                            and (providerState == 'started' or providerState == 'starting')
                            and providerHealthy and foundation.semverSatisfies(version, requirement.range) then
                            compatible = true
                            break
                        end
                    end
                    if compatible then break end
                end
                if not compatible then
                    findings[#findings + 1] = {
                        consumer = consumer, service = service, range = requirement.range,
                        severity = requirement.optional and 'warning'
                            or (requirement.critical and 'error' or 'warning'), kind = 'dependency'
                    }
                end
            end
        end
        table.sort(findings, function(a, b)
            if a.consumer == b.consumer then return a.service < b.service end
            return a.consumer < b.consumer
        end)
        return findings
    end
    function dependencies:snapshot() return foundation.copy(graph) end

    return {
        core = stateMachine,
        scheduler = scheduler,
        dependencies = dependencies,
        reload = reload
    }
end
