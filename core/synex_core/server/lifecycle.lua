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
    local scheduler = {}
    local function schedule(owner, epoch, delay, recurring, handler, options)
        if type(delay) ~= 'number' or delay < 0 or delay > 86400000 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Schedule delay is outside the supported range.')
        end
        if type(handler) ~= 'function' then return nil, foundation.error('INVALID_ARGUMENT', 'Schedule handler is required.') end
        options = type(options) == 'table' and options or {}
        if options.name ~= nil and (type(options.name) ~= 'string' or #options.name < 3 or #options.name > 96
            or not options.name:match('^[a-z][a-z0-9_.%-]*$')) then
            return nil, foundation.error('INVALID_ARGUMENT', 'Worker name is invalid.')
        end
        local token = foundation.nextId('schedule')
        local entry = {
            owner = owner, epoch = epoch, cancelled = false, delay = delay, recurring = recurring,
            name = options.name or token, health = recurring and 'STARTING' or 'SCHEDULED',
            lastRun = nil, durationMs = nil, lastError = nil, runs = 0, consecutiveFailures = 0
        }
        schedules[token] = entry
        local function run()
            if entry.cancelled or not deps.owners:isCurrent(owner, epoch) then
                schedules[token] = nil
                return
            end
            local invocation = { cancelled = false }
            local operationToken = deps.owners:beginOperation(owner, epoch, function()
                invocation.cancelled = true
            end)
            if not operationToken then
                schedules[token] = nil
                deps.owners:release(owner, 'schedule', token)
                return
            end
            local started = foundation.monotonicMs()
            local ok, result, handlerError = foundation.safeCall(handler, token)
            deps.owners:finishOperation(owner, epoch, operationToken)
            entry.lastRun = foundation.utcIso()
            entry.durationMs = math.max(0, foundation.monotonicMs() - started)
            entry.runs = entry.runs + 1
            if not ok or handlerError ~= nil or result == false then
                local failure = not ok and result or handlerError or 'handler returned false'
                entry.consecutiveFailures = entry.consecutiveFailures + 1
                entry.health = entry.consecutiveFailures >= 3 and 'UNHEALTHY' or 'DEGRADED'
                entry.lastError = (type(failure) == 'table' and tostring(failure.code or failure.message) or tostring(failure)):sub(1, 512)
                logger:error('scheduled handler failed', {
                    owner = owner, worker = entry.name, token = token, error = entry.lastError,
                    consecutiveFailures = entry.consecutiveFailures
                })
            else
                entry.consecutiveFailures = 0
                entry.health = 'HEALTHY'
                entry.lastError = nil
            end
            if entry.recurring and not entry.cancelled and not invocation.cancelled and deps.owners:isCurrent(owner, epoch) then
                platform.setTimeout(entry.delay, run)
            else
                schedules[token] = nil
                deps.owners:release(owner, 'schedule', token)
            end
        end
        local _, trackErr = deps.owners:track(owner, epoch, 'schedule', token, function()
            entry.cancelled = true
            schedules[token] = nil
        end)
        if trackErr then
            entry.cancelled = true
            schedules[token] = nil
            return nil, trackErr
        end
        platform.setTimeout(delay, run)
        return token, nil
    end
    function scheduler:after(owner, epoch, delay, handler, options) return schedule(owner, epoch, delay, false, handler, options) end
    function scheduler:every(owner, epoch, delay, handler, options)
        if type(delay) ~= 'number' or delay < 50 then
            return nil, foundation.error('INVALID_ARGUMENT', 'Recurring schedules must be at least 50 ms.')
        end
        return schedule(owner, epoch, delay, true, handler, options)
    end
    function scheduler:cancel(owner, token)
        local entry = schedules[token]
        if not entry or entry.owner ~= owner then return false end
        entry.cancelled = true
        schedules[token] = nil
        deps.owners:release(owner, 'schedule', token)
        return true
    end
    function scheduler:count()
        local count = 0
        for _ in pairs(schedules) do count = count + 1 end
        return count
    end
    function scheduler:snapshot()
        local result = {}
        for token, entry in pairs(schedules) do
            result[#result + 1] = {
                token = token, name = entry.name, resource = entry.owner,
                intervalMs = entry.delay, recurring = entry.recurring,
                health = entry.health, lastRun = entry.lastRun, durationMs = entry.durationMs,
                lastError = entry.lastError, runs = entry.runs
            }
        end
        table.sort(result, function(a, b)
            if a.resource == b.resource then return a.name < b.name end
            return a.resource < b.resource
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
                    details = tostring(waitError)
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
                    details = tostring(value)
                })
            elseif value == nil then
                if type(captureError) == 'table' and type(captureError.code) == 'string' then
                    snapshotError = captureError
                else
                    snapshotError = foundation.error('SNAPSHOT_CAPTURE_FAILED', 'The reconstructable state snapshot failed.', {
                        details = captureError ~= nil and tostring(captureError) or nil
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
                details = tostring(value)
            })
        end
        if value == nil then
            if type(restoreError) == 'table' and type(restoreError.code) == 'string' then return nil, restoreError end
            return nil, foundation.error('SNAPSHOT_RESTORE_FAILED', 'The reconstructable state restore failed.', {
                details = restoreError ~= nil and tostring(restoreError) or nil
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
        graph.providers[service] = graph.providers[service] or {}
        graph.providers[service][provider] = version
        graph.providerHealth[service] = graph.providerHealth[service] or {}
        graph.providerHealth[service][provider] = { health = 'HEALTHY', circuit = 'CLOSED' }
        return true, nil
    end
    function dependencies:setProviderHealth(provider, service, health, circuit)
        local providers = graph.providers[service]
        if not (providers and providers[provider]) then
            return nil, foundation.error('PROVIDER_NOT_REGISTERED', 'Provider health requires a registered service provider.')
        end
        if health ~= 'HEALTHY' and health ~= 'DEGRADED' and health ~= 'UNHEALTHY' then
            return nil, foundation.error('INVALID_PROVIDER_HEALTH', 'Provider health is invalid.')
        end
        if circuit ~= 'CLOSED' and circuit ~= 'HALF_OPEN' and circuit ~= 'OPEN' then
            return nil, foundation.error('INVALID_PROVIDER_CIRCUIT', 'Provider circuit state is invalid.')
        end
        graph.providerHealth[service] = graph.providerHealth[service] or {}
        graph.providerHealth[service][provider] = { health = health, circuit = circuit }
        return true, nil
    end
    function dependencies:removeProvider(provider, selectedService)
        for service, providers in pairs(graph.providers) do
            if selectedService == nil or service == selectedService then
                providers[provider] = nil
                if graph.providerHealth[service] then graph.providerHealth[service][provider] = nil end
            end
        end
    end
    function dependencies:validate(inactiveResource)
        local findings = {}
        for consumer, requirements in pairs(graph.consumers) do
            local state = type(platform.resourceState) == 'function' and platform.resourceState(consumer) or 'started'
            local consumerActive = consumer ~= inactiveResource and (state == 'started' or state == 'starting')
            for service, requirement in pairs(consumerActive and requirements or {}) do
                local compatible = false
                for provider, version in pairs(graph.providers[service] or {}) do
                    local providerState = type(platform.resourceState) == 'function'
                        and platform.resourceState(provider) or 'started'
                    local runtimeHealth = graph.providerHealth[service]
                        and graph.providerHealth[service][provider] or nil
                    local providerHealthy = runtimeHealth == nil
                        or (runtimeHealth.health ~= 'UNHEALTHY' and runtimeHealth.circuit ~= 'OPEN')
                    if provider ~= inactiveResource and (providerState == 'started' or providerState == 'starting')
                        and providerHealthy and foundation.semverSatisfies(version, requirement.range) then
                        compatible = true
                        break
                    end
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
