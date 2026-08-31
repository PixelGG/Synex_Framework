SynexNotifyRegistry = {}

local Validation = assert(SynexNotifyValidation, 'notify validation must be loaded first')
local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded first')

local EVENT_NAME = 'synex_notify:client:command:v1'
local TERMINAL_PROGRESS = { SUCCESS = true, FAILED = true, CANCELLED = true }
local PROGRESS_TRANSITIONS = {
    PENDING = { PENDING = true, RUNNING = true, SUCCESS = true, FAILED = true, CANCELLED = true },
    RUNNING = { RUNNING = true, SUCCESS = true, FAILED = true, CANCELLED = true },
    SUCCESS = {}, FAILED = {}, CANCELLED = {},
}

function SynexNotifyRegistry.create(options)
    local foundation = assert(options.foundation, 'notify registry requires foundation')
    local now = assert(options.now, 'notify registry requires monotonic time')
    local utc = assert(options.utc, 'notify registry requires UTC time')
    local nextId = assert(options.nextId, 'notify registry requires an ID provider')
    local getSession = assert(options.getSession, 'notify registry requires session authority')
    local triggerClient = assert(options.triggerClient, 'notify registry requires client transport')
    local checkPrivilege = assert(options.checkPrivilege, 'notify registry requires capability delegation')
    local isSystemPrincipal = options.isSystemPrincipal or function() return false end
    local observability = assert(options.observability, 'notify registry requires observability')
    local getPlayers = options.getPlayers or GetPlayers
    local getResourceState = options.getResourceState or GetResourceState
    local records, order, actions, handlers, history = {}, {}, {}, {}, {}
    local pendingCommands, pendingCommandsPerSource = {}, {}
    local pendingCommandCount = 0
    local budgets = {}
    local ownerCounts, ownerActiveCounts, ownerActivity = {}, {}, {}
    local ownerEpochSeen = {}
    local maximumRecords = Limits.maximumServerNotifications or 512
    local maximumOwnerRecords = Limits.maximumOwnerNotifications or 64
    local maximumActions = Limits.maximumActionTokens or 512
    local maximumHistory = Limits.maximumHistory or 128
    local maximumSendMany = Limits.maximumSendMany or 32
    local maximumBroadcast = Limits.maximumBroadcastTargets or 256
    local maximumPendingCommands = Limits.maximumPendingCommands or 1024
    local maximumPendingCommandsPerSource = Limits.maximumPendingCommandsPerSource or 128
    local pendingCommandTtlMs = Limits.pendingCommandTtlMs or 10000
    local registry = {}
    local recordActivity

    local function refillBucket(key, policy)
        local current = now()
        local bucket = budgets[key]
        if not bucket then
            bucket = { tokens = policy.capacity, updatedAt = current }
            budgets[key] = bucket
            return bucket
        end
        local elapsed = math.max(0, current - bucket.updatedAt)
        bucket.tokens = math.min(policy.capacity,
            bucket.tokens + elapsed * policy.refillPerSecond / 1000)
        bucket.updatedAt = current
        return bucket
    end

    local function planBudget(owner, scopes)
        local pending = {}
        for _, scope in ipairs(scopes) do
            local policy = Limits.rateLimits and Limits.rateLimits[scope.name]
            if type(policy) == 'table' and type(policy.capacity) == 'number'
                and type(policy.refillPerSecond) == 'number' then
                local key = scope.global == true and scope.name
                    or (owner .. ':' .. scope.name)
                local bucket = refillBucket(key, policy)
                local cost = math.max(0, tonumber(scope.cost) or 1)
                if bucket.tokens < cost then
                    observability.increment('rateLimited')
                    recordActivity(owner, 'rateLimited', 1)
                    return Validation.failure('NOTIFY_RATE_LIMITED',
                        'The notification budget is temporarily exhausted.', true)
                end
                pending[#pending + 1] = { bucket = bucket, cost = cost }
            end
        end
        return pending
    end

    local function commitBudget(pending)
        for _, entry in ipairs(pending) do
            entry.bucket.tokens = entry.bucket.tokens - entry.cost
        end
        return true
    end

    local function planSendBudget(owner, notification)
        local costs = Limits.notificationCosts or {}
        local kindCost = costs[notification.kind] or 1
        local priorityCost = costs[notification.priority] or 1
        local scopes = {
            { name = 'global', global = true, cost = math.max(kindCost, priorityCost) },
            { name = 'owner', cost = math.max(kindCost, priorityCost) },
            { name = notification.kind, cost = 1 },
        }
        if notification.priority == 'high' or notification.priority == 'critical' then
            scopes[#scopes + 1] = { name = notification.priority, cost = 1 }
        end
        return planBudget(owner, scopes)
    end

    local function publicHandle(record)
        return {
            notificationId = record.notificationId,
            ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch,
            revision = record.revision,
        }
    end

    recordActivity = function(owner, field, amount, priority)
        local entry = ownerActivity[owner]
        if not entry then
            entry = { created = 0, updated = 0, dismissed = 0, actions = 0,
                high = 0, critical = 0, rateLimited = 0, payloadRejected = 0,
                capabilityDenied = 0 }
            ownerActivity[owner] = entry
        end
        entry[field] = (entry[field] or 0) + (amount or 1)
        if priority == 'high' or priority == 'critical' then
            entry[priority] = entry[priority] + (amount or 1)
        end
    end

    local function capabilityDenied(owner, message)
        observability.increment('capabilityDenied')
        recordActivity(owner, 'capabilityDenied', 1)
        return Validation.failure('NOTIFY_OWNER_INVALID', message)
    end

    local function appendHistory(record, state, reason)
        if record.history == false then return end
        history[#history + 1] = {
            notificationId = record.notificationId,
            ownerResource = record.ownerResource,
            kind = record.kind,
            tone = record.tone,
            priority = record.priority,
            origin = record.origin,
            state = state,
            reason = reason,
            occurredAt = utc(),
        }
        if #history > maximumHistory then table.remove(history, 1) end
    end

    local function currentTarget(target)
        local session, sessionError = getSession(target.source)
        if not session then
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The target player session is no longer active.', true)
        end
        if session.state ~= 'ACTIVE' or session.id ~= target.sessionId
            or session.source ~= target.source
            or session.sourceGeneration ~= target.sourceGeneration then
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The target player session changed before delivery.', true)
        end
        return session, sessionError
    end

    local function removePendingCommand(commandId)
        local entry = pendingCommands[commandId]
        if not entry then return false end
        pendingCommands[commandId] = nil
        pendingCommandCount = math.max(0, pendingCommandCount - 1)
        local source = entry.target.source
        local count = math.max(0, (pendingCommandsPerSource[source] or 1) - 1)
        pendingCommandsPerSource[source] = count > 0 and count or nil
        return true
    end

    local function prunePendingCommands(current)
        local removed = 0
        for commandId, entry in pairs(pendingCommands) do
            if current >= entry.expiresAt then
                if removePendingCommand(commandId) then removed = removed + 1 end
            end
        end
        return removed
    end

    local function removePendingCommands(predicate)
        local removed = 0
        for commandId, entry in pairs(pendingCommands) do
            if predicate(entry) and removePendingCommand(commandId) then
                removed = removed + 1
            end
        end
        return removed
    end

    local function stageCommand(record, command, payload, current)
        prunePendingCommands(current)
        local source = record.target.source
        if pendingCommandCount >= maximumPendingCommands
            or (pendingCommandsPerSource[source] or 0) >= maximumPendingCommandsPerSource then
            return Validation.failure('NOTIFY_QUEUE_FULL',
                'The bounded notification command registry is full.', true)
        end
        local commandId, idError = nextId('notify_command')
        if not Validation.identifier(commandId, 16, 96)
            or pendingCommands[commandId] ~= nil then
            return nil, idError or {
                code = 'NOTIFY_UNAVAILABLE',
                message = 'A notification command identifier could not be allocated.',
                retryable = true,
            }
        end
        local envelope = {
            schemaVersion = Limits.schemaVersion or 1,
            command = command,
            commandId = commandId,
            ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch,
            notificationId = record.notificationId,
            revision = record.revision,
            target = foundation.copy(record.target),
        }
        if payload ~= nil then envelope.payload = foundation.copy(payload) end
        pendingCommands[commandId] = {
            command = envelope,
            target = foundation.copy(record.target),
            ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch,
            expiresAt = current + pendingCommandTtlMs,
        }
        pendingCommandCount = pendingCommandCount + 1
        pendingCommandsPerSource[source] = (pendingCommandsPerSource[source] or 0) + 1
        return commandId, nil
    end

    local function dispatch(record, command, payload)
        local _, targetError = currentTarget(record.target)
        if targetError then return nil, targetError end
        local current = now()
        local commandId, commandError = stageCommand(record, command, payload, current)
        if not commandId then return nil, commandError end
        local wake = {
            schemaVersion = Limits.schemaVersion or 1,
            commandId = commandId,
        }
        local started = current
        local delivered, transportError = pcall(triggerClient, record.target.source,
            EVENT_NAME, wake)
        if not delivered then
            removePendingCommand(commandId)
            observability.increment('transportFailures')
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification transport is temporarily unavailable.', true)
        end
        observability.observeWakeDispatch(now() - started)
        observability.increment('wakeDispatched')
        return true, transportError
    end

    local function removeActions(record)
        for _, action in ipairs(record.actions or {}) do
            if action.token then actions[action.token] = nil end
        end
        record.actions = {}
    end

    local function actionCount()
        local count = 0
        for _ in pairs(actions) do count = count + 1 end
        return count
    end

    local function activeRecordActionCount(record)
        local count = 0
        for _, action in ipairs(record.actions or {}) do
            if action.token and actions[action.token] ~= nil then count = count + 1 end
        end
        return count
    end

    local function markRecordActionUsed(record, token)
        for _, action in ipairs(record and record.actions or {}) do
            if action.token == token then action.used = true; return end
        end
    end

    local function removeRecordAction(record, token)
        for index = #(record and record.actions or {}), 1, -1 do
            if record.actions[index].token == token then table.remove(record.actions, index) end
        end
    end

    local function prepareActions(definitions, expiryLimit, currentTime)
        local issued, issuedTokens = {}, {}
        for _, definition in ipairs(definitions) do
            local token, tokenError = nextId('notify_action')
            if not Validation.identifier(token, 16, 96)
                or actions[token] ~= nil or issuedTokens[token] then
                return nil, tokenError or {
                    code = 'NOTIFY_UNAVAILABLE',
                    message = 'A notification action token could not be allocated.',
                    retryable = true,
                }
            end
            issuedTokens[token] = true
            local ttl = tonumber(definition.ttlMs) or 10000
            local expiresAt = currentTime + ttl
            if type(expiryLimit) == 'number' then expiresAt = math.min(expiresAt, expiryLimit) end
            ttl = math.floor(expiresAt - currentTime)
            if ttl < (Limits.minimumActionTtlMs or 1000) then
                return Validation.failure('NOTIFY_ACTION_EXPIRED',
                    'The notification lifetime is too short for a new action.')
            end
            local action = {
                token = token,
                id = definition.id,
                label = definition.label,
                hint = definition.hint,
                style = definition.style,
                expiresAt = expiresAt,
                ttlMs = ttl,
                used = false,
            }
            issued[#issued + 1] = action
        end
        return issued
    end

    local function commitActions(record, issued, revision)
        local stored = {}
        for _, action in ipairs(issued) do
            stored[#stored + 1] = {
                token = action.token,
                notificationId = record.notificationId,
                ownerResource = record.ownerResource,
                ownerEpoch = record.ownerEpoch,
                revision = revision or record.revision,
                target = foundation.copy(record.target),
                actionId = action.id,
                expiresAt = action.expiresAt,
                used = false,
            }
        end
        removeActions(record)
        for _, action in ipairs(stored) do actions[action.token] = action end
        record.actions = issued
        local registered = handlers[record.notificationId]
        if type(registered) == 'table' then
            local declared = {}
            for _, action in ipairs(issued) do declared[action.id] = true end
            for actionId in pairs(registered) do
                if actionId ~= '*' and not declared[actionId] then
                    registered[actionId] = nil
                end
            end
        end
        return true
    end

    local function presentation(record, projectedActions, currentTime)
        local value = {
            notificationId = record.notificationId,
            kind = record.kind,
            tone = record.tone,
            priority = record.priority,
            title = record.title,
            message = record.message,
            iconKey = record.iconKey,
            progress = foundation.copy(record.progress),
            dedupeKey = record.dedupeKey,
            dedupePolicy = record.dedupePolicy,
            groupKey = record.groupKey,
            durationMs = record.durationMs,
            maxLifetimeMs = record.maxLifetimeMs,
            maxRefreshCount = record.maxRefreshCount,
            history = record.history,
            sound = record.sound,
            position = record.position,
            origin = record.origin,
            createdAt = record.createdAt,
            revision = record.revision,
            actions = {},
        }
        local sourceActions = projectedActions or record.actions or {}
        for _, action in ipairs(sourceActions) do
            local stored = projectedActions ~= nil and action
                or action.token and actions[action.token] or nil
            local remaining = math.floor(action.expiresAt - (currentTime or now()))
            if stored and not stored.used
                and remaining >= (Limits.minimumActionTtlMs or 1000) then
                value.actions[#value.actions + 1] = {
                    token = action.token,
                    label = action.label,
                    hint = action.hint,
                    style = action.style,
                    ttlMs = math.min(action.ttlMs, remaining),
                }
            end
        end
        return value
    end

    local function validatedPresentation(record, projectedActions, currentTime)
        return Validation.canonicalPresentation(
            presentation(record, projectedActions, currentTime), {
                authority = record.origin,
                ownerResource = record.ownerResource,
                now = currentTime or now(),
            })
    end

    local function recordExpiry(record, baseTime, duration, progressValue)
        local hardExpiry = record.hardExpiry or record.absoluteExpiry
            or (baseTime + (record.maxLifetimeMs or Limits.maximumLifetimeMs or 120000))
        -- The server cannot observe when a queued client presentation becomes
        -- visible. Retain the authoritative handle to its hard lifetime; the
        -- client owns visible-duration expiry and can revive a dormant record
        -- when a later full server update arrives.
        return hardExpiry
    end

    local function actionExpiry(record, baseTime, duration)
        local hardExpiry = record.hardExpiry or record.absoluteExpiry
            or (baseTime + (record.maxLifetimeMs or Limits.maximumLifetimeMs or 120000))
        local visibleDuration = duration or record.durationMs
        if visibleDuration == nil then return hardExpiry end
        return math.min(hardExpiry, baseTime + visibleDuration)
    end

    local function nextActionExpiry(record, current, duration, progressValue, revive)
        if revive or type(progressValue) == 'table'
            and TERMINAL_PROGRESS[progressValue.state] then
            return actionExpiry(record, current, duration)
        end
        local deadline = record.actionExpiry
            or actionExpiry(record, record.createdAt or current, record.durationMs)
        if duration ~= nil then
            deadline = math.min(deadline,
                actionExpiry(record, record.createdAt or current, duration))
        end
        return deadline
    end

    local function requirePrivilege(owner, payload, operation)
        if payload.origin == 'SYSTEM' and isSystemPrincipal(owner) then return true end
        local requirements = { 'synex.notify.send' }
        if payload.origin == 'SYSTEM' then
            requirements[#requirements + 1] = 'synex.notify.system'
        end
        if payload.priority == 'high' then
            requirements[#requirements + 1] = 'synex.notify.priority.high'
        elseif payload.priority == 'critical' then
            requirements[#requirements + 1] = 'synex.notify.priority.critical'
        end
        if payload.kind == 'banner' then
            requirements[#requirements + 1] = 'synex.notify.banner'
        end
        for _, capability in ipairs(requirements) do
            local allowed, privilegeError = checkPrivilege(owner, capability, operation)
            if not allowed then
                observability.increment('capabilityDenied')
                recordActivity(owner, 'capabilityDenied', 1)
                local code = capability:find('priority', 1, true)
                    and 'NOTIFY_PRIORITY_DENIED' or 'NOTIFY_OWNER_INVALID'
                return Validation.failure(code,
                    'The calling resource is not authorized for this notification operation.')
            end
        end
        return true
    end

    local function requireMutationPrivilege(owner, record, operation)
        if record.origin == 'SYSTEM' and isSystemPrincipal(owner) then return true end
        local allowed = checkPrivilege(owner, 'synex.notify.update', operation)
        if not allowed then
            return capabilityDenied(owner,
                'The calling resource is not authorized to mutate notifications.')
        end
        if record.origin == 'SYSTEM' then
            allowed = checkPrivilege(owner, 'synex.notify.system', operation)
            if not allowed then
                return capabilityDenied(owner,
                    'The calling resource is no longer authorized for system notifications.')
            end
        end
        return true
    end

    local function privilegedAuditRequired(record)
        return type(record) == 'table'
            and (record.origin == 'SYSTEM' or record.priority == 'critical')
    end

    local function auditDelivery(action, owner, record, context, sent, failed)
        if not privilegedAuditRequired(record) then return false end
        observability.audit(action, 'resource', owner, {
            deliveryScope = action == 'notify.privileged.send' and 'single' or 'multiple',
            kind = record.kind,
            origin = record.origin,
            priority = record.priority,
            sent = math.max(0, math.floor(tonumber(sent) or 0)),
            failed = math.max(0, math.floor(tonumber(failed) or 0)),
        }, type(context) == 'table' and context.traceId or nil)
        return true
    end

    local function suppressedAuditContext(context)
        local value = foundation.copy(type(context) == 'table' and context or {})
        value.suppressPrivilegedAudit = true
        return value
    end

    local function recordCount()
        local count = 0
        for _ in pairs(records) do count = count + 1 end
        return count
    end

    local function activeRecordCount()
        local count = 0
        for _, record in pairs(records) do
            if record.presentationActive then count = count + 1 end
        end
        return count
    end

    local function decrementOwnerCounter(counters, owner)
        local remaining = math.max(0, (counters[owner] or 1) - 1)
        counters[owner] = remaining > 0 and remaining or nil
    end

    local function deactivatePresentation(record)
        if not record.presentationActive then return false end
        record.presentationActive = false
        decrementOwnerCounter(ownerActiveCounts, record.ownerResource)
        removeActions(record)
        return true
    end

    local function forget(record, state, reason)
        records[record.notificationId] = nil
        if record.presentationActive then
            decrementOwnerCounter(ownerActiveCounts, record.ownerResource)
        end
        decrementOwnerCounter(ownerCounts, record.ownerResource)
        handlers[record.notificationId] = nil
        removeActions(record)
        for index = #order, 1, -1 do
            if order[index] == record.notificationId then table.remove(order, index) end
        end
        appendHistory(record, state, reason)
    end

    local function compactPresentations(current)
        local compacted = 0
        for _, record in pairs(records) do
            if record.presentationActive and type(record.presentationExpiry) == 'number'
                and current >= record.presentationExpiry then
                if deactivatePresentation(record) then compacted = compacted + 1 end
            end
        end
        return compacted
    end

    local function oldestInactive(owner, excluded)
        for _, notificationId in ipairs(order) do
            local record = records[notificationId]
            if record and not record.presentationActive
                and not excluded[notificationId]
                and (owner == nil or record.ownerResource == owner) then
                return record
            end
        end
        return nil
    end

    local function planRecordCapacity(owner, current)
        compactPresentations(current)
        local planned, excluded = {}, {}
        local total, ownerTotal = recordCount(), ownerCounts[owner] or 0
        while total >= maximumRecords or ownerTotal >= maximumOwnerRecords do
            local candidate = nil
            if ownerTotal >= maximumOwnerRecords then
                candidate = oldestInactive(owner, excluded)
            end
            if candidate == nil and total >= maximumRecords then
                candidate = oldestInactive(nil, excluded)
            end
            if candidate == nil then
                return Validation.failure('NOTIFY_QUEUE_FULL',
                    'The bounded server notification registry is full.', true)
            end
            excluded[candidate.notificationId] = true
            planned[#planned + 1] = candidate
            total = total - 1
            if candidate.ownerResource == owner then ownerTotal = ownerTotal - 1 end
        end
        return planned
    end

    local function commitCapacityPlan(planned)
        for _, candidate in ipairs(planned) do
            candidate.revision = candidate.revision + 1
            dispatch(candidate, 'dismiss', { reason = 'queue_evicted' })
            forget(candidate, 'EVICTED', 'registry_pressure')
        end
    end

    local function validateOwner(owner, epoch)
        local resource, resourceError = Validation.resourceName(owner)
        if not resource then return nil, resourceError end
        if not Validation.isInteger(epoch, 1, 9007199254740991) then
            return Validation.failure('NOTIFY_OWNER_INVALID',
                'The notification owner epoch is invalid.')
        end
        local latest = ownerEpochSeen[resource]
        if latest ~= nil and epoch < latest then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification owner incarnation is stale.')
        end
        if latest ~= nil and epoch > latest then
            registry.cleanupOwner(resource, latest)
        end
        ownerEpochSeen[resource] = epoch
        return resource
    end

    function registry.send(owner, epoch, targetValue, payloadValue, context)
        local resource, ownerError = validateOwner(owner, epoch)
        if not resource then return nil, ownerError end
        local target, targetError = Validation.targetRef(targetValue)
        if not target then return nil, targetError end
        local origin = 'SERVER'
        if type(context) == 'table' and context.origin ~= nil then
            if context.origin ~= 'SYSTEM' then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'The internal notification origin is invalid.')
            end
            origin = 'SYSTEM'
        end
        local validationStartedAt = now()
        local canonical, payloadError = Validation.canonicalNotification(payloadValue, {
            authority = origin, ownerResource = resource, now = now(),
        })
        observability.observeValidation(now() - validationStartedAt)
        if not canonical then
            observability.increment('payloadRejected')
            recordActivity(resource, 'payloadRejected', 1)
            return nil, payloadError
        end
        local privileged, privilegeError = requirePrivilege(resource, canonical,
            context and context.operation or 'notify.send')
        if not privileged then return nil, privilegeError end
        local _, currentError = currentTarget(target)
        if currentError then return nil, currentError end
        local current = now()
        local capacityPlan, capacityError = planRecordCapacity(resource, current)
        if not capacityPlan then return nil, capacityError end
        local actionDefinitions = canonical.actions or {}
        if actionCount() + #actionDefinitions > maximumActions then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The bounded notification action registry is full.', true)
        end
        local notificationId, idError = nextId('notify')
        if not Validation.identifier(notificationId, 8, 96)
            or records[notificationId] ~= nil then
            return nil, idError or {
                code = 'NOTIFY_UNAVAILABLE',
                message = 'A notification identifier could not be allocated.',
                retryable = true,
            }
        end
        local created = current
        local record = canonical
        record.notificationId = notificationId
        record.ownerResource = resource
        record.ownerEpoch = epoch
        record.revision = 1
        record.target = target
        record.createdAt = created
        record.hardExpiry = created + (record.maxLifetimeMs
            or Limits.maximumLifetimeMs or 120000)
        record.absoluteExpiry = recordExpiry(record, created)
        record.actionExpiry = actionExpiry(record, created)
        record.presentationExpiry = actionExpiry(record, created)
        record.presentationActive = true
        actionDefinitions = record.actions or {}
        record.actions = {}
        local preparedActions, actionError = prepareActions(actionDefinitions,
            record.actionExpiry, current)
        if not preparedActions then return nil, actionError end
        local projected, projectionError = validatedPresentation(record,
            preparedActions, current)
        if not projected then
            observability.increment('payloadRejected')
            recordActivity(resource, 'payloadRejected', 1)
            return nil, projectionError
        end
        local budgetPlan, budgetError = planSendBudget(resource, canonical)
        if not budgetPlan then return nil, budgetError end
        commitActions(record, preparedActions)
        local delivered, deliveryError = dispatch(record, 'show', projected)
        if not delivered then
            removeActions(record)
            return nil, deliveryError
        end
        commitBudget(budgetPlan)
        commitCapacityPlan(capacityPlan)
        records[notificationId] = record
        order[#order + 1] = notificationId
        ownerCounts[resource] = (ownerCounts[resource] or 0) + 1
        ownerActiveCounts[resource] = (ownerActiveCounts[resource] or 0) + 1
        observability.increment('created')
        recordActivity(resource, 'created', 1, record.priority)
        appendHistory(record, 'CREATED', nil)
        if type(context) ~= 'table' or context.suppressPrivilegedAudit ~= true then
            auditDelivery('notify.privileged.send', resource, record, context, 1, 0)
        end
        return publicHandle(record), nil
    end

    local function ownedRecord(owner, epoch, handleValue, allowNewerRevision)
        local handle, handleError = Validation.handle(handleValue)
        if not handle then return nil, handleError end
        if handle.ownerResource ~= owner or handle.ownerEpoch ~= epoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification handle belongs to another owner incarnation.')
        end
        local record = records[handle.notificationId]
        if not record then
            return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                'The notification no longer exists.')
        end
        if record.ownerResource ~= owner or record.ownerEpoch ~= epoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification owner incarnation is stale.')
        end
        if now() >= record.absoluteExpiry then
            forget(record, 'EXPIRED', 'max_lifetime')
            return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                'The notification no longer exists.')
        end
        if record.presentationActive and now() >= record.presentationExpiry then
            deactivatePresentation(record)
        end
        if allowNewerRevision ~= true and record.revision ~= handle.revision then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The notification handle revision is stale.')
        end
        return record
    end

    function registry.update(owner, epoch, handleValue, patchValue, context)
        local record, recordError = ownedRecord(owner, epoch, handleValue, false)
        if not record then return nil, recordError end
        local allowed, privilegeError = requireMutationPrivilege(owner, record,
            context and context.operation or 'notify.update')
        if not allowed then return nil, privilegeError end
        local patch, patchError = Validation.notificationPatch(patchValue, {
            authority = record.origin, kind = record.kind,
        })
        if not patch then return nil, patchError end
        if patch.progress then
            if record.kind ~= 'progress' or type(record.progress) ~= 'table' then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'Progress state can update only a progress notification.')
            end
            local transition = PROGRESS_TRANSITIONS[record.progress.state]
            if not transition or not transition[patch.progress.state] then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'The requested progress transition is not legal.')
            end
            if record.progress.mode == 'determinate' and patch.progress.mode == 'determinate'
                and patch.progress.state == 'RUNNING'
                and tonumber(patch.progress.value) < tonumber(record.progress.value) then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'Determinate progress cannot move backwards.')
            end
        end
        if patch.actions and actionCount() - activeRecordActionCount(record)
            + #patch.actions > maximumActions then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The bounded notification action registry is full.', true)
        end
        local current = now()
        local nextRevision = record.revision + 1
        local nextProgress = patch.progress or record.progress
        local nextDuration = patch.durationMs or record.durationMs
        if type(nextProgress) == 'table' and TERMINAL_PROGRESS[nextProgress.state] then
            nextDuration = patch.durationMs or Limits.terminalDurationMs or 4000
        end
        local revive = not record.presentationActive
        local nextActionDeadline = nextActionExpiry(record, current, nextDuration,
            nextProgress, revive)
        local nextExpiry = recordExpiry(record, current, nextDuration, nextProgress)
        local nextPresentationDeadline = record.presentationExpiry
        if revive or type(nextProgress) == 'table'
            and TERMINAL_PROGRESS[nextProgress.state] then
            nextPresentationDeadline = actionExpiry(record, current, nextDuration)
        elseif nextDuration ~= nil then
            nextPresentationDeadline = math.min(nextPresentationDeadline,
                actionExpiry(record, record.createdAt or current, nextDuration))
        end
        local preparedActions = nil
        if patch.actions then
            local actionError
            preparedActions, actionError = prepareActions(patch.actions,
                nextActionDeadline, current)
            if not preparedActions then return nil, actionError end
        end
        local previous = {
            revision = record.revision,
            absoluteExpiry = record.absoluteExpiry,
            actionExpiry = record.actionExpiry,
            presentationExpiry = record.presentationExpiry,
            presentationActive = record.presentationActive,
            durationMs = record.durationMs,
            actions = foundation.copy(record.actions or {}),
            handlers = foundation.copy(handlers[record.notificationId]),
            fields = {}, actionRecords = {},
        }
        for key in pairs(patch) do
            if key ~= 'actions' then
                previous.fields[key] = {
                    present = record[key] ~= nil,
                    value = foundation.copy(record[key]),
                }
            end
        end
        for _, action in ipairs(record.actions or {}) do
            if action.token and actions[action.token] then
                previous.actionRecords[action.token] = foundation.copy(actions[action.token])
            end
        end
        if preparedActions then
            commitActions(record, preparedActions, nextRevision)
        end
        record.revision = nextRevision
        for key, value in pairs(patch) do
            if key ~= 'actions' then record[key] = foundation.copy(value) end
        end
        if not patch.actions then
            for _, action in ipairs(record.actions or {}) do
                local stored = actions[action.token]
                action.expiresAt = math.min(action.expiresAt, nextActionDeadline)
                action.ttlMs = math.max(0, math.floor(action.expiresAt - current))
                if stored then
                    stored.revision = record.revision
                    stored.expiresAt = action.expiresAt
                end
            end
        end
        if record.progress and TERMINAL_PROGRESS[record.progress.state] then
            record.durationMs = patch.durationMs or Limits.terminalDurationMs or 4000
        end
        record.absoluteExpiry = nextExpiry
        record.actionExpiry = nextActionDeadline
        record.presentationExpiry = nextPresentationDeadline
        if revive then record.presentationActive = true end

        local function restorePrevious()
            removeActions(record)
            record.actions = previous.actions
            for token, action in pairs(previous.actionRecords) do actions[token] = action end
            handlers[record.notificationId] = previous.handlers
            record.revision = previous.revision
            record.absoluteExpiry = previous.absoluteExpiry
            record.actionExpiry = previous.actionExpiry
            record.presentationExpiry = previous.presentationExpiry
            record.presentationActive = previous.presentationActive
            record.durationMs = previous.durationMs
            for key, field in pairs(previous.fields) do
                record[key] = field.present and field.value or nil
            end
        end

        local projected, projectionError = validatedPresentation(record, nil, current)
        if not projected then
            restorePrevious()
            observability.increment('payloadRejected')
            recordActivity(owner, 'payloadRejected', 1)
            return nil, projectionError
        end
        local budgetPlan, budgetError = planBudget(owner, {
            { name = 'update', cost = 1 },
        })
        if not budgetPlan then
            restorePrevious()
            return nil, budgetError
        end
        local delivered, deliveryError = dispatch(record, 'update', projected)
        if not delivered then
            restorePrevious()
            return nil, deliveryError
        end
        commitBudget(budgetPlan)
        if revive then
            ownerActiveCounts[owner] = (ownerActiveCounts[owner] or 0) + 1
        end
        if record.presentationActive and current >= record.presentationExpiry then
            deactivatePresentation(record)
        end
        recordActivity(owner, 'updated', 1)
        return publicHandle(record), nil
    end

    function registry.completeProgress(owner, epoch, handleValue, state, tone, message, context)
        local record, recordError = ownedRecord(owner, epoch, handleValue, false)
        if not record then return nil, recordError end
        if record.kind ~= 'progress' or type(record.progress) ~= 'table'
            or not TERMINAL_PROGRESS[state] then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Only progress notifications can use terminal operations.')
        end
        local progress = foundation.copy(record.progress)
        progress.state = state
        return registry.update(owner, epoch, handleValue, {
            tone = tone,
            message = message,
            progress = progress,
            durationMs = Limits.terminalDurationMs or 4000,
        }, context)
    end

    function registry.dismiss(owner, epoch, handleValue, reason, context)
        local record, recordError = ownedRecord(owner, epoch, handleValue, false)
        if not record then return nil, recordError end
        local allowed, privilegeError = requireMutationPrivilege(owner, record,
            context and context.operation or 'notify.dismiss')
        if not allowed then return nil, privilegeError end
        if reason ~= nil and reason ~= 'dismissed' and reason ~= 'cancelled'
            and reason ~= 'superseded' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification dismissal reason is invalid.')
        end
        local budgetPlan, budgetError = planBudget(owner, {
            { name = 'update', cost = 1 },
        })
        if not budgetPlan then return nil, budgetError end
        local previousRevision = record.revision
        record.revision = previousRevision + 1
        local delivered, deliveryError = dispatch(record, 'dismiss', {
            reason = reason or 'dismissed',
        })
        if not delivered and (type(deliveryError) ~= 'table'
            or deliveryError.code ~= 'NOTIFY_TARGET_STALE') then
            record.revision = previousRevision
            return nil, deliveryError
        end
        commitBudget(budgetPlan)
        local id = record.notificationId
        forget(record, reason == 'cancelled' and 'CANCELLED' or 'DISMISSED',
            reason or 'dismissed')
        recordActivity(owner, 'dismissed', 1)
        return { notificationId = id, dismissed = true }, nil
    end

    function registry.sendMany(owner, epoch, targets, payload, context)
        local count = Validation.arrayLength(targets, maximumSendMany)
        if count == nil or count < 1 then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'sendMany requires a bounded non-empty target array.')
        end
        local results = { sent = 0, failed = 0, handles = {}, errors = {} }
        local sendContext = suppressedAuditContext(context)
        for index, target in ipairs(targets) do
            local handle, sendError = registry.send(owner, epoch, target, payload, sendContext)
            if handle then
                results.sent = results.sent + 1
                results.handles[#results.handles + 1] = handle
            else
                results.failed = results.failed + 1
                results.errors[#results.errors + 1] = {
                    index = index,
                    code = type(sendError) == 'table' and sendError.code or 'NOTIFY_UNAVAILABLE',
                }
            end
        end
        local first = results.handles[1]
        local firstRecord = first and records[first.notificationId] or nil
        auditDelivery('notify.privileged.send_many', owner, firstRecord, context,
            results.sent, results.failed)
        return results, nil
    end

    function registry.broadcast(owner, epoch, payload, context)
        local systemOrigin = type(context) == 'table' and context.origin == 'SYSTEM'
        if type(context) == 'table' and context.origin ~= nil and not systemOrigin then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The internal notification origin is invalid.')
        end
        local systemPrincipal = systemOrigin and isSystemPrincipal(owner)
        if systemOrigin and not systemPrincipal then
            local allowed = checkPrivilege(owner, 'synex.notify.system',
                'notify.broadcast_system')
            if not allowed then return capabilityDenied(owner,
                'The calling resource is not authorized for system notifications.') end
        end
        if not systemPrincipal then
            local allowed = checkPrivilege(owner, 'synex.notify.broadcast',
                context and context.operation or 'notify.broadcast')
            if not allowed then return capabilityDenied(owner,
                'The calling resource is not authorized to broadcast notifications.') end
        end
        local raw = getPlayers()
        if type(raw) ~= 'table' or #raw > maximumBroadcast then
            return Validation.failure('NOTIFY_QUEUE_FULL',
                'The bounded broadcast target set is unavailable.', true)
        end
        local targets = {}
        for _, sourceValue in ipairs(raw) do
            local source = tonumber(sourceValue)
            local session = source and getSession(source) or nil
            if session and session.state == 'ACTIVE' then
                targets[#targets + 1] = {
                    source = session.source,
                    sessionId = session.id,
                    sourceGeneration = session.sourceGeneration,
                }
            end
        end
        local results = { sent = 0, failed = 0, handles = {}, errors = {} }
        local sendContext = suppressedAuditContext(context)
        for index, target in ipairs(targets) do
            local handle, sendError = registry.send(owner, epoch, target, payload, sendContext)
            if handle then
                results.sent = results.sent + 1
                results.handles[#results.handles + 1] = handle
            else
                results.failed = results.failed + 1
                results.errors[#results.errors + 1] = {
                    index = index,
                    code = type(sendError) == 'table'
                        and sendError.code or 'NOTIFY_UNAVAILABLE',
                }
            end
        end
        local first = results.handles[1]
        local firstRecord = first and records[first.notificationId] or nil
        observability.audit('notify.broadcast', 'resource', owner, {
            deliveryScope = 'broadcast',
            origin = firstRecord and firstRecord.origin
                or (systemOrigin and 'SYSTEM' or 'SERVER'),
            priority = firstRecord and firstRecord.priority or nil,
            kind = firstRecord and firstRecord.kind or nil,
            targets = #targets,
            sent = results.sent,
            failed = results.failed,
        }, type(context) == 'table' and context.traceId or nil)
        return results, nil
    end

    function registry.onAction(notificationId, owner, epoch, actionId, handler)
        local record = records[notificationId]
        if not record or record.ownerResource ~= owner or record.ownerEpoch ~= epoch then
            return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                'The notification action owner is unavailable.')
        end
        if handler == nil and foundation.isCallable(actionId) then
            handler, actionId = actionId, '*'
        end
        if type(actionId) ~= 'string' or (actionId ~= '*' and (#actionId < 1
            or #actionId > 64 or not actionId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'))) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification action identifier is invalid.')
        end
        if actionId ~= '*' then
            local declared = false
            for _, action in ipairs(record.actions or {}) do
                if action.id == actionId then declared = true; break end
            end
            if not declared then
                return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                    'The notification action is not declared by this notification.')
            end
        end
        if not foundation.isCallable(handler) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Notification action handlers must be callable.')
        end
        local registered = handlers[notificationId] or {}
        registered[actionId] = handler
        handlers[notificationId] = registered
        return true
    end

    function registry.pullCommand(request, context)
        if not Validation.exactObject(request, { commandId = true })
            or not Validation.identifier(request.commandId, 16, 96) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification command pull request is invalid.')
        end
        local current = now()
        prunePendingCommands(current)
        local entry = pendingCommands[request.commandId]
        if not entry then
            return Validation.failure('NOTIFY_COMMAND_NOT_FOUND',
                'The notification command is unavailable.')
        end
        local session = type(context) == 'table' and context.session or nil
        local source = type(context) == 'table' and context.source or nil
        local sourceGeneration = type(context) == 'table'
            and context.sourceGeneration or nil
        if type(session) ~= 'table' or session.state ~= 'ACTIVE'
            or source ~= entry.target.source or session.source ~= entry.target.source
            or session.id ~= entry.target.sessionId
            or session.sourceGeneration ~= entry.target.sourceGeneration
            or sourceGeneration ~= entry.target.sourceGeneration then
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The notification command belongs to another player session.')
        end
        local detached = foundation.copy(entry.command)
        removePendingCommand(request.commandId)
        local _, targetError = currentTarget(entry.target)
        if targetError then
            return nil, targetError
        end
        return detached, nil
    end

    function registry.invokeAction(request, context)
        if not Validation.exactObject(request, {
            token = true, notificationId = true, revision = true,
        }) or not Validation.identifier(request.token, 16, 96)
            or not Validation.identifier(request.notificationId, 8, 96)
            or not Validation.isInteger(request.revision, 1, 9007199254740991) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification action request is invalid.')
        end
        local action = actions[request.token]
        if not action or action.notificationId ~= request.notificationId then
            return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                'The notification action no longer exists.')
        end
        if action.used then
            observability.increment('actionReplayed')
            return Validation.failure('NOTIFY_ACTION_REPLAYED',
                'The notification action has already been used.')
        end
        if now() >= action.expiresAt then
            actions[request.token] = nil
            local expiredRecord = records[action.notificationId]
            if expiredRecord then removeRecordAction(expiredRecord, request.token) end
            observability.increment('actionExpired')
            return Validation.failure('NOTIFY_ACTION_EXPIRED',
                'The notification action expired.')
        end
        local record = records[action.notificationId]
        if not record or record.revision ~= request.revision
            or action.revision ~= request.revision then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The notification action revision is stale.')
        end
        local session = type(context) == 'table' and context.session or nil
        local source = type(context) == 'table' and context.source or nil
        if type(session) ~= 'table' or session.id ~= action.target.sessionId
            or source ~= action.target.source
            or session.sourceGeneration ~= action.target.sourceGeneration then
            return Validation.failure('NOTIFY_TARGET_STALE',
                'The action belongs to another player session.')
        end
        action.used = true
        markRecordActionUsed(record, request.token)
        local registered = handlers[action.notificationId]
        local callback = type(registered) == 'table'
            and (registered[action.actionId] or registered['*']) or nil
        local callbackPayload = {
            notificationId = action.notificationId,
            actionId = action.actionId,
            ownerResource = action.ownerResource,
            session = foundation.copy(action.target),
            occurredAt = utc(),
            traceId = context.traceId,
        }
        if callback then
            local _, callbackError = foundation.protect(callback, callbackPayload)
            if callbackError then
                return Validation.failure('NOTIFY_UNAVAILABLE',
                    'The notification owner did not accept the action.', true)
            end
        end
        observability.event('synex.notify.action', callbackPayload, context)
        observability.increment('actions')
        recordActivity(action.ownerResource, 'actions', 1)
        return { accepted = true, actionId = action.actionId }, nil
    end

    function registry.cleanupOwner(owner, maximumEpoch)
        local affected, targets = {}, {}
        removePendingCommands(function(entry)
            return entry.ownerResource == owner
                and (maximumEpoch == nil or entry.ownerEpoch <= maximumEpoch)
        end)
        for _, id in ipairs(order) do
            local record = records[id]
            if record and record.ownerResource == owner
                and (maximumEpoch == nil or record.ownerEpoch <= maximumEpoch) then
                affected[#affected + 1] = record
                targets[record.target.source] = record.target
            end
        end
        for _, record in ipairs(affected) do forget(record, 'OWNER_STOPPED', 'owner_stopped') end
        for _, target in pairs(targets) do
            local placeholder = {
                notificationId = 'owner-stop', ownerResource = owner,
                ownerEpoch = maximumEpoch or 9007199254740991,
                revision = 1, target = target,
            }
            dispatch(placeholder, 'owner_stop', nil)
        end
        observability.increment('ownerCleanup', #affected)
        local newerEpoch = maximumEpoch ~= nil
            and (ownerEpochSeen[owner] or 0) > maximumEpoch
        if not newerEpoch then
            ownerActivity[owner] = nil
            ownerEpochSeen[owner] = nil
            ownerCounts[owner] = nil
            ownerActiveCounts[owner] = nil
            for key in pairs(budgets) do
                if key:sub(1, #owner + 1) == owner .. ':' then budgets[key] = nil end
            end
        end
        return { removed = #affected }, nil
    end

    function registry.playerDropped(source)
        local affected = {}
        removePendingCommands(function(entry)
            return entry.target.source == source
        end)
        for _, id in ipairs(order) do
            local record = records[id]
            if record and record.target.source == source then affected[#affected + 1] = record end
        end
        for _, record in ipairs(affected) do forget(record, 'CANCELLED', 'player_dropped') end
        return #affected
    end

    function registry.expire()
        local current, expiredActions, expiredRecords = now(), 0, 0
        local expiredCommands = prunePendingCommands(current)
        local compactedPresentations = compactPresentations(current)
        for token, action in pairs(actions) do
            if action.used or current >= action.expiresAt then
                actions[token] = nil
                expiredActions = expiredActions + 1
            end
        end
        for _, record in pairs(records) do
            for index = #(record.actions or {}), 1, -1 do
                local token = record.actions[index].token
                if token == nil or actions[token] == nil then
                    table.remove(record.actions, index)
                end
            end
        end
        local stale = {}
        for _, id in ipairs(order) do
            local record = records[id]
            if record and current >= record.absoluteExpiry then stale[#stale + 1] = record end
        end
        for _, record in ipairs(stale) do
            record.revision = record.revision + 1
            dispatch(record, 'dismiss', { reason = 'expired' })
            forget(record, 'EXPIRED', 'max_lifetime')
            expiredRecords = expiredRecords + 1
        end
        return { actions = expiredActions, commands = expiredCommands,
            notifications = expiredRecords,
            presentations = compactedPresentations }
    end

    function registry.clearPendingCommands()
        local removed = pendingCommandCount
        pendingCommands, pendingCommandsPerSource = {}, {}
        pendingCommandCount = 0
        return removed
    end

    function registry.snapshot()
        local active, presenting = recordCount(), activeRecordCount()
        local progress, actionTotal = 0, actionCount()
        local owners = {}
        for owner, count in pairs(ownerCounts) do
            if count > 0 then
                local activity = ownerActivity[owner] or {}
                owners[#owners + 1] = {
                    ownerResource = owner, active = count,
                    presenting = ownerActiveCounts[owner] or 0,
                    created = activity.created or 0,
                    updated = activity.updated or 0,
                    dismissed = activity.dismissed or 0,
                    actions = activity.actions or 0,
                    high = activity.high or 0,
                    critical = activity.critical or 0,
                    rateLimited = activity.rateLimited or 0,
                    payloadRejected = activity.payloadRejected or 0,
                    capabilityDenied = activity.capabilityDenied or 0,
                }
            end
        end
        table.sort(owners, function(left, right)
            return left.ownerResource < right.ownerResource
        end)
        for _, record in pairs(records) do
            if record.kind == 'progress' and record.progress
                and not TERMINAL_PROGRESS[record.progress.state] then progress = progress + 1 end
        end
        return {
            active = active, presenting = presenting,
            retained = math.max(0, active - presenting), progressActive = progress,
            actionTokens = actionTotal, pendingCommands = pendingCommandCount,
            maximumPendingCommands = maximumPendingCommands,
            maximumPendingCommandsPerSource = maximumPendingCommandsPerSource,
            pendingCommandTtlMs = pendingCommandTtlMs, ownerCount = #owners,
            maximumRecords = maximumRecords,
            budgetBuckets = (function()
                local total = 0
                for _ in pairs(budgets) do total = total + 1 end
                return total
            end)(),
            owners = owners, metrics = observability.snapshot(),
            history = foundation.copy(history),
        }
    end

    function registry.doctor(limit)
        local maximum = math.max(1, math.min(tonumber(limit) or 50, 100))
        local findings, current = {}, now()
        local ownerChecked, staleTargetChecked = {}, {}
        local function finding(code, severity, scope, message)
            if #findings >= maximum then return end
            findings[#findings + 1] = {
                code = code, severity = severity, scope = scope, message = message,
            }
        end
        if recordCount() >= math.floor(maximumRecords * 0.8) then
            finding('NOTIFICATION_QUEUE_PRESSURE', 'warning', 'registry',
                'The bounded server delivery registry is above 80% capacity.')
        end
        if actionCount() >= math.floor(maximumActions * 0.8) then
            finding('ACTION_BACKLOG', 'warning', 'actions',
                'The bounded action-token registry is above 80% capacity.')
        end
        if pendingCommandCount >= math.floor(maximumPendingCommands * 0.8) then
            finding('COMMAND_BACKLOG', 'warning', 'transport',
                'The bounded pending-command registry is above 80% capacity.')
        end
        if getResourceState('synex_ui') ~= 'started' then
            finding('UI_RUNTIME_UNAVAILABLE', 'warning', 'ui',
                'The optional Synex UI runtime is unavailable; only critical native fallback is possible.')
        end
        for _, action in pairs(actions) do
            if current >= action.expiresAt then
                finding('EXPIRED_ACTION_TOKEN', 'warning', 'actions',
                    'An expired action token is awaiting the bounded expiry worker.')
                break
            end
        end
        for _, record in pairs(records) do
            if not ownerChecked[record.ownerResource] then
                ownerChecked[record.ownerResource] = true
                local state = getResourceState(record.ownerResource)
                if state ~= 'started' and state ~= 'starting' then
                    finding('OWNER_LEAK', 'warning', record.ownerResource,
                        'A retained notification belongs to a resource that is not active.')
                end
            end
            local targetKey = table.concat({ tostring(record.target.source),
                record.target.sessionId, tostring(record.target.sourceGeneration) }, ':')
            if not staleTargetChecked[targetKey] then
                staleTargetChecked[targetKey] = true
                local _, targetError = currentTarget(record.target)
                if targetError then
                    finding('STALE_NOTIFICATION_TARGET', 'warning', record.ownerResource,
                        'A retained notification target no longer matches an active session.')
                end
            end
            if record.kind == 'progress' and record.progress
                and not TERMINAL_PROGRESS[record.progress.state]
                and current - record.createdAt > 60000 then
                finding('ORPHAN_PROGRESS_NOTIFICATION', 'warning', record.ownerResource,
                    'An active progress notification exceeded the orphan threshold.')
            end
        end
        for owner, activity in pairs(ownerActivity) do
            local created = activity.created or 0
            local privileged = (activity.high or 0) + (activity.critical or 0)
            if created >= 20 and privileged / created > 0.8 then
                finding('NOTIFICATION_PRIORITY_ABUSE', 'warning', owner,
                    'Most notifications from this owner use privileged priority.')
            end
            if created >= 100 then
                finding('NOTIFICATION_SPAM', 'warning', owner,
                    'The owner created an unusually large notification burst.')
            end
            if (activity.rateLimited or 0) >= 20 then
                finding('NOTIFICATION_RATE_LIMIT_PRESSURE', 'warning', owner,
                    'The owner repeatedly exhausted a notification budget.')
            end
            if (activity.payloadRejected or 0) >= 20 then
                finding('NOTIFICATION_PAYLOAD_ABUSE', 'warning', owner,
                    'The owner repeatedly submitted invalid notification payloads.')
            end
        end
        local state = #findings == 0 and 'READY' or 'DEGRADED'
        return { status = state, findings = findings, truncated = #findings >= maximum }, nil
    end

    registry.publicHandle = publicHandle
    registry.records = function() return records end
    return registry
end
