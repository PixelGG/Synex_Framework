SynexNotifyEngine = {}

local Limits = assert(SynexNotifyLimits, 'notify limits must be loaded before client engine')
local Validation = assert(SynexNotifyValidation,
    'notify validation must be loaded before client engine')
local MAXIMUM_SAFE_INTEGER = Limits.maximumSafeInteger
local priorityWeight = { low = 0, normal = 20, high = 40, critical = 60 }
local positionOrder = {
    'top-right', 'top-left', 'bottom-right', 'bottom-left',
    'top-center', 'bottom-center',
}
local MAXIMUM_PRESENTATION_CONTEXTS = 16
local MAXIMUM_CONTEXT_ID_BYTES = 64
local MAXIMUM_CONTEXT_POSITIONS = 6
local UI_MESSAGE_BYTES = 512
local UI_ACTION_TOKEN_BYTES = 64
local progressTransitions = {
    PENDING = { PENDING = true, RUNNING = true, SUCCESS = true, FAILED = true,
        CANCELLED = true },
    RUNNING = { RUNNING = true, SUCCESS = true, FAILED = true, CANCELLED = true },
    SUCCESS = {}, FAILED = {}, CANCELLED = {},
}

-- Cfx serializes cross-resource functions as callable table/userdata proxies.
local function isCallable(value)
    local valueType = type(value)
    if valueType == 'function' then return true end
    if valueType ~= 'table' and valueType ~= 'userdata' then return false end
    local readable, metatable = pcall(getmetatable, value)
    if not readable then metatable = nil end
    if type(metatable) ~= 'table'
        and type(debug) == 'table' and type(debug.getmetatable) == 'function' then
        local rawReadable, rawMetatable = pcall(debug.getmetatable, value)
        if rawReadable then metatable = rawMetatable end
    end
    return type(metatable) == 'table'
        and type(rawget(metatable, '__call')) == 'function'
end

function SynexNotifyEngine.create(options)
    options = options or {}
    local now = assert(options.now, 'notify engine requires a monotonic clock')
    local upsertSignal = assert(options.upsertSignal,
        'notify engine requires a UI upsert function')
    local removeSignal = assert(options.removeSignal,
        'notify engine requires a UI remove function')
    local nativeFallback = options.nativeFallback or function() return false end
    local invokeServerAction = options.invokeServerAction or function()
        return Validation.failure('NOTIFY_UNAVAILABLE',
            'The notification action transport is unavailable.', true)
    end
    local playSound = options.playSound or function() return false end
    local actionHint = options.actionHint or function(_, configured) return configured end
    local observe = options.observe or function() end
    local records, queue, visible, history = {}, {}, {}, {}
    local serverAliases, dedupe, groups, actionTokens = {}, {}, {}, {}
    local uiVisibleRevisions = {}
    local uiVisibilityConfirmed = false
    local serverTombstones, serverTombstoneOrder, serverTombstoneCount = {}, {}, 0
    local maximumServerTombstones = Limits.maximumServerNotifications or 512
    local budgetBuckets, bursts = {}, {}
    local latestOwnerEpoch = {}
    local presentationContexts = {}
    local presentationQuiet = false
    local presentationPlan = {
        quiet = false, reserved = {}, reservedPositions = {},
        fallbackPositions = {}, preferredPosition = nil, contextCount = 0,
    }
    local uiPreferences = {
        scale = 100,
        reducedMotion = false,
        reducedTransparency = false,
        highContrast = false,
    }
    local presentationPreferences = {
        position = 'auto',
        durationScale = 100,
        soundEnabled = false,
        soundVolume = 100,
        muteNonCriticalSounds = false,
        history = true,
    }
    local sequence, lastPromotedOwner, consecutiveOwner = 0, nil, 0
    local soundEnabled, lastSoundAt, active = false, -Limits.soundMinimumIntervalMs, true
    local lastActionInvokeAt = -Limits.actionMinimumIntervalMs
    local visibleCapacity = Limits.maximumVisible
    local engine = {}

    local function ownerEpochKey(owner, authority)
        return authority .. '\0epoch\0' .. owner
    end

    local function acceptOwnerEpoch(owner, epoch, authority)
        local key = ownerEpochKey(owner, authority)
        local latest = latestOwnerEpoch[key]
        if latest ~= nil and epoch < latest then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification owner incarnation is stale.')
        end
        if latest ~= nil and epoch > latest then
            engine.ownerStop(owner, latest, authority)
        end
        latestOwnerEpoch[key] = epoch
        return true
    end

    local function metric(name, amount)
        pcall(observe, name, amount or 1)
    end

    local function recordCount()
        local count = 0
        for _ in pairs(records) do count = count + 1 end
        return count
    end

    local function visibleCount()
        local count = 0
        for _ in pairs(visible) do count = count + 1 end
        return count
    end

    local function removeFromArray(values, expected)
        for index = #values, 1, -1 do
            if values[index] == expected then table.remove(values, index) end
        end
    end

    local function forgetServerTombstone(notificationId)
        if serverTombstones[notificationId] == nil then return end
        serverTombstones[notificationId] = nil
        serverTombstoneCount = math.max(0, serverTombstoneCount - 1)
        removeFromArray(serverTombstoneOrder, notificationId)
    end

    local function pruneServerTombstones(current)
        for notificationId, tombstone in pairs(serverTombstones) do
            if current >= tombstone.hardExpiresAt then
                forgetServerTombstone(notificationId)
            end
        end
        while #serverTombstoneOrder > 0 do
            local notificationId = serverTombstoneOrder[1]
            if serverTombstones[notificationId] ~= nil then break end
            table.remove(serverTombstoneOrder, 1)
        end
    end

    local function rememberServerTombstones(record, current)
        pruneServerTombstones(current)
        for notificationId, revision in pairs(record.sourceRevisions or {}) do
            if serverTombstones[notificationId] == nil then
                while serverTombstoneCount >= maximumServerTombstones
                    and #serverTombstoneOrder > 0 do
                    local oldest = table.remove(serverTombstoneOrder, 1)
                    forgetServerTombstone(oldest)
                end
                serverTombstoneOrder[#serverTombstoneOrder + 1] = notificationId
                serverTombstoneCount = serverTombstoneCount + 1
            end
            serverTombstones[notificationId] = {
                ownerResource = record.ownerResource,
                ownerEpoch = record.ownerEpoch,
                origin = record.origin,
                revision = revision,
                hardExpiresAt = record.hardExpiresAt,
                createdAt = record.createdAt,
            }
        end
    end

    local function publicHandle(record)
        return {
            notificationId = record.notificationId,
            ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch,
            revision = record.localRevision or record.uiRevision,
        }
    end

    local function refill(bucket, capacity, perSecond, current)
        local elapsed = math.max(0, current - bucket.at)
        bucket.tokens = math.min(capacity, bucket.tokens + elapsed * perSecond / 1000)
        bucket.at = current
    end

    local function consumeBudget(owner, scopes, current)
        local pending = {}
        for _, scope in ipairs(scopes) do
            local policy = Limits.rateLimits and Limits.rateLimits[scope.name]
            if type(policy) ~= 'table' or type(policy.capacity) ~= 'number'
                or type(policy.refillPerSecond) ~= 'number' then
                metric('rate_limited')
                return false
            end
            local key = scope.global == true and ('\0global\0' .. scope.name)
                or (owner .. '\0' .. scope.name)
            local bucket = budgetBuckets[key]
            if not bucket then
                bucket = { tokens = policy.capacity, at = current }
                budgetBuckets[key] = bucket
            end
            refill(bucket, policy.capacity, policy.refillPerSecond, current)
            local cost = math.max(0, tonumber(scope.cost) or 1)
            if bucket.tokens < cost then
                metric('rate_limited')
                return false
            end
            pending[#pending + 1] = { bucket = bucket, cost = cost }
        end
        for _, entry in ipairs(pending) do
            entry.bucket.tokens = entry.bucket.tokens - entry.cost
        end
        return true
    end

    local function consumePresentation(owner, candidate, current)
        local costs = Limits.notificationCosts or {}
        local cost = math.max(costs[candidate.kind] or 1,
            costs[candidate.priority] or 1)
        local scopes = {
            { name = 'global', global = true, cost = cost },
            { name = 'owner', cost = cost },
            { name = candidate.kind, cost = 1 },
        }
        if candidate.priority == 'high' or candidate.priority == 'critical' then
            scopes[#scopes + 1] = { name = candidate.priority, cost = 1 }
        end
        return consumeBudget(owner, scopes, current)
    end

    local function consumeUpdate(owner, current)
        return consumeBudget(owner, { { name = 'update', cost = 1 } }, current)
    end

    local function rebuildPresentationPlan()
        local keys = {}
        for key in pairs(presentationContexts) do keys[#keys + 1] = key end
        table.sort(keys)
        local plan = {
            quiet = false, reserved = {}, reservedPositions = {},
            fallbackPositions = {}, preferredPosition = nil,
            contextCount = #keys,
        }
        local fallbackSeen = {}
        for _, key in ipairs(keys) do
            local context = presentationContexts[key]
            if context.quiet then plan.quiet = true end
            for _, position in ipairs(context.reservedPositions) do
                plan.reserved[position] = true
            end
        end
        for _, position in ipairs(positionOrder) do
            if plan.reserved[position] then
                plan.reservedPositions[#plan.reservedPositions + 1] = position
            end
        end
        for _, key in ipairs(keys) do
            local context = presentationContexts[key]
            if plan.preferredPosition == nil and context.preferredPosition ~= nil
                and not plan.reserved[context.preferredPosition] then
                plan.preferredPosition = context.preferredPosition
            end
            for _, position in ipairs(context.fallbackPositions) do
                if not plan.reserved[position] and not fallbackSeen[position] then
                    fallbackSeen[position] = true
                    plan.fallbackPositions[#plan.fallbackPositions + 1] = position
                end
            end
        end
        presentationPlan = plan
        presentationQuiet = plan.quiet
        return plan
    end

    local function resolvePosition(requested)
        local preferred = presentationPreferences.position
        if preferred ~= 'auto' and not presentationPlan.reserved[preferred] then
            return preferred
        end
        if presentationPlan.preferredPosition ~= nil then
            return presentationPlan.preferredPosition
        end
        if not presentationPlan.reserved[requested] then return requested end
        for _, position in ipairs(presentationPlan.fallbackPositions) do
            if not presentationPlan.reserved[position] then return position end
        end
        for _, position in ipairs(positionOrder) do
            if not presentationPlan.reserved[position] then return position end
        end
        return requested
    end

    local function effectiveDuration(requested, maximumLifetime)
        if requested == nil then return nil end
        local scaled = math.floor(requested * presentationPreferences.durationScale
            / 100 + 0.5)
        return math.min(maximumLifetime or Limits.maximumLifetimeMs,
            math.max(Limits.minimumDurationMs,
                math.min(Limits.maximumDurationMs, scaled)))
    end

    local function boundedPositionArray(value)
        if value == nil then return {} end
        local count = Validation.arrayLength(value, MAXIMUM_CONTEXT_POSITIONS)
        if count == nil then return nil end
        local copied = Validation.copy(value)
        if type(copied) ~= 'table' then return nil end
        local seen = {}
        local result = {}
        for index = 1, count do
            local position = rawget(copied, index)
            if not Limits.positions[position] or seen[position] then return nil end
            seen[position] = true
            result[index] = position
        end
        return result
    end

    local function canonicalPresentationContext(value)
        if not Validation.exactObject(value, {
            contextId = true, quiet = true, reservedPositions = true,
            preferredPosition = true, fallbackPositions = true,
        }) or type(value.contextId) ~= 'string'
            or #value.contextId < 1 or #value.contextId > MAXIMUM_CONTEXT_ID_BYTES
            or value.contextId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or value.quiet ~= nil and type(value.quiet) ~= 'boolean'
            or value.preferredPosition ~= nil
                and not Limits.positions[value.preferredPosition] then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The presentation context is invalid.')
        end
        local reserved = boundedPositionArray(value.reservedPositions)
        local fallback = boundedPositionArray(value.fallbackPositions)
        if reserved == nil or fallback == nil then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Presentation context positions must be bounded and unique.')
        end
        return {
            contextId = value.contextId,
            quiet = value.quiet == true,
            reservedPositions = reserved,
            preferredPosition = value.preferredPosition,
            fallbackPositions = fallback,
        }
    end

    local function appendHistory(record, state, reason, current)
        if record.history == false or presentationPreferences.history == false then return end
        history[#history + 1] = {
            notificationId = record.notificationId,
            ownerResource = record.ownerResource,
            ownerEpoch = record.ownerEpoch,
            kind = record.kind,
            tone = record.tone,
            priority = record.priority,
            origin = record.origin,
            state = state,
            reason = reason,
            occurredAt = current,
        }
        if #history > Limits.maximumHistory then table.remove(history, 1) end
    end

    local function purgeActions(record, sourceId)
        local retained = {}
        for _, action in ipairs(record.actions or {}) do
            if sourceId == nil or action.sourceNotificationId == sourceId then
                actionTokens[action.token] = nil
            else
                retained[#retained + 1] = action
            end
        end
        record.actions = retained
    end

    local function installActions(record, definitions, authority, sourceId, sourceRevision,
        current)
        record.actionGeneration = (record.actionGeneration or 0) + 1
        local previousExpiry, previousDisplayToken = {}, {}
        for _, action in ipairs(record.actions or {}) do
            previousExpiry[action.token] = action.expiresAt
            previousDisplayToken[action.token] = action.displayToken
        end
        purgeActions(record)
        record.actions = {}
        for index, definition in ipairs(definitions or {}) do
            sequence = sequence + 1
            local token = definition.token
            if authority == 'LOCAL' then
                token = ('local-action:%08x:%08x'):format(
                    math.floor(record.ownerEpoch) & 0xffffffff, sequence & 0xffffffff)
            end
            local requestedExpiry = current
                + (definition.ttlMs or Limits.defaultActionTtlMs)
            local expiresAt = previousExpiry[token] or requestedExpiry
            if authority == 'SERVER' and previousExpiry[token] ~= nil then
                expiresAt = math.min(previousExpiry[token], requestedExpiry)
            end
            expiresAt = math.min(expiresAt, record.hardExpiresAt or expiresAt)
            if record.expiresAt ~= nil then
                expiresAt = math.min(expiresAt, record.expiresAt)
            end
            local displayToken = previousDisplayToken[token]
            if displayToken == nil then
                displayToken = ('notify-action:%08x:%08x'):format(
                    record.sequence & 0xffffffff, sequence & 0xffffffff)
            end
            local action = {
                token = token,
                displayToken = displayToken,
                id = definition.id,
                label = definition.label,
                hint = definition.hint,
                style = definition.style or 'quiet',
                expiresAt = expiresAt,
                authority = authority,
                sourceNotificationId = sourceId or record.notificationId,
                sourceRevision = sourceRevision or record.localRevision,
                used = false,
            }
            record.actions[index] = action
            actionTokens[token] = action
        end
    end

    local function utf8Prefix(value, maximumBytes)
        if type(value) ~= 'string' then return nil end
        local limit = math.min(#value, maximumBytes)
        local index, last = 1, 0
        while index <= limit do
            local first = value:byte(index)
            local width = 1
            if first <= 0x7f then
                width = 1
            elseif first >= 0xc2 and first <= 0xdf then
                width = 2
            elseif first >= 0xe0 and first <= 0xef then
                width = 3
            elseif first >= 0xf0 and first <= 0xf4 then
                width = 4
            else
                break
            end
            if index + width - 1 > limit then break end
            local second = width > 1 and value:byte(index + 1) or nil
            if second and (second < 0x80 or second > 0xbf) then break end
            if width == 3 then
                local third = value:byte(index + 2)
                if third < 0x80 or third > 0xbf
                    or first == 0xe0 and second < 0xa0
                    or first == 0xed and second > 0x9f then break end
            elseif width == 4 then
                local third, fourth = value:byte(index + 2), value:byte(index + 3)
                if third < 0x80 or third > 0xbf or fourth < 0x80 or fourth > 0xbf
                    or first == 0xf0 and second < 0x90
                    or first == 0xf4 and second > 0x8f then break end
            end
            last = index + width - 1
            index = last + 1
        end
        return value:sub(1, last)
    end

    local function groupIndexFor(record)
        if record.groupKey == nil then return nil end
        return table.concat({ record.ownerResource, tostring(record.ownerEpoch),
            record.origin or record.authority, record.groupKey, record.kind, record.tone,
            record.priority }, '\0g\0')
    end

    local function dedupeIndexFor(record)
        if record.dedupeKey == nil then return nil end
        return table.concat({ record.ownerResource, tostring(record.ownerEpoch),
            record.origin or record.authority, record.dedupeKey }, '\0d\0')
    end

    local function clearDedupeIndex(record)
        if record.dedupeIndex and dedupe[record.dedupeIndex]
            and dedupe[record.dedupeIndex].recordId == record.signalId then
            dedupe[record.dedupeIndex] = nil
        end
        record.dedupeIndex = nil
    end

    local function reindexDedupe(record, current)
        if record.dedupeKey == nil then return end
        clearDedupeIndex(record)
        local index = dedupeIndexFor(record)
        local occupied = index and dedupe[index] or nil
        if occupied and occupied.recordId ~= record.signalId then return end
        record.dedupeIndex = index
        dedupe[index] = { recordId = record.signalId, at = current }
    end

    local function clearGroupIndex(record)
        if record.groupIndex and groups[record.groupIndex]
            and groups[record.groupIndex].recordId == record.signalId then
            groups[record.groupIndex] = nil
        end
        record.groupIndex = nil
    end

    local function reindexGroup(record, current)
        if record.groupKey == nil then return end
        clearGroupIndex(record)
        local index = groupIndexFor(record)
        local occupied = index and groups[index] or nil
        if occupied and occupied.recordId ~= record.signalId then return end
        record.groupIndex = index
        groups[index] = { recordId = record.signalId, at = current }
    end

    local function selectedVisibleAction(index, current, requireRendered)
        local selected = nil
        for _, record in pairs(visible) do
            local available = {}
            local confirmedRevision = uiVisibleRevisions[record.signalId]
            local eligible = confirmedRevision ~= nil
                and (record.actionProjectionGeneration or 0)
                    == (record.actionGeneration or 0)
            if requireRendered then
                eligible = eligible and record.lastRenderedRevision == record.uiRevision
                    and confirmedRevision == record.uiRevision
            end
            if eligible then
                for _, action in ipairs(record.actions or {}) do
                    if not action.used and current < action.expiresAt then
                        available[#available + 1] = action
                    end
                end
            end
            if available[index] and (selected == nil
                or priorityWeight[record.priority] > priorityWeight[selected.record.priority]
                or priorityWeight[record.priority] == priorityWeight[selected.record.priority]
                    and (record.visibleAt < selected.record.visibleAt
                        or record.visibleAt == selected.record.visibleAt
                            and record.sequence < selected.record.sequence)) then
                selected = { record = record, action = available[index] }
            end
        end
        return selected
    end

    local function signalDescriptor(record, current)
        local descriptor = {
            signalId = record.signalId,
            revision = record.uiRevision,
            kind = record.kind,
            tone = record.tone,
            priority = record.priority,
            title = utf8Prefix(record.title, Limits.maximumTitleBytes),
            createdAt = record.createdAt,
            position = record.position,
        }
        if record.message ~= nil then
            descriptor.message = utf8Prefix(record.message, UI_MESSAGE_BYTES)
        end
        if record.iconKey ~= nil then descriptor.iconKey = record.iconKey end
        if record.count ~= nil and record.count > 1 then descriptor.count = record.count end
        if record.progress ~= nil then descriptor.progress = Validation.copy(record.progress) end
        if record.expiresAt ~= nil and record.expiresAt > record.createdAt then
            descriptor.expiresAt = record.expiresAt
        end
        local projected = {}
        local availableIndex = 0
        for _, action in ipairs(record.actions or {}) do
            if #projected >= Limits.maximumActions then break end
            if not action.used and current < action.expiresAt then
                availableIndex = availableIndex + 1
                local selected = selectedVisibleAction(availableIndex, current, false)
                if selected and selected.record == record and selected.action == action then
                    projected[#projected + 1] = {
                        token = utf8Prefix(action.displayToken, UI_ACTION_TOKEN_BYTES),
                        label = action.label,
                        hint = actionHint(availableIndex, action.hint),
                        style = action.style == 'quiet' and 'default' or action.style,
                    }
                end
            end
        end
        if #projected > 0 then descriptor.actions = projected end
        return descriptor
    end

    local function criticalFallback(record, descriptor)
        if record.priority ~= 'critical'
            or record.fallbackGeneration == record.presentationGeneration then
            return false
        end
        record.fallbackGeneration = record.presentationGeneration
        record.visibilityAckDeadline = nil
        record.visibilityAckRevision = nil
        local fallbackOk, fallbackResult = pcall(nativeFallback, descriptor)
        if fallbackOk and fallbackResult then
            record.presentedOnce = true
            metric('native_fallbacks')
            return true
        end
        return false
    end

    local function render(record, current, force)
        if not active or record.state ~= 'visible' then return false end
        if not force and record.pendingRenderAt ~= nil and current < record.pendingRenderAt then
            return false
        end
        record.pendingRenderAt = nil
        local firstPresentation = record.presentedOnce ~= true
        local descriptor = signalDescriptor(record, current)
        metric('render_dispatches')
        uiVisibilityConfirmed = false
        local dispatchStartedAt = now()
        local invoked, result, renderError = pcall(upsertSignal, descriptor)
        metric('render_dispatch_samples')
        metric('render_dispatch_time_ms', math.max(0, now() - dispatchStartedAt))
        local accepted = invoked and result ~= nil and result ~= false and renderError == nil
        local delivered = accepted
            and (type(result) ~= 'table' or result.delivered ~= false)
        local presented = delivered
        if accepted then
            record.lastRenderedRevision = record.uiRevision
        end
        if delivered then
            metric('displayed')
            record.renderAckRevision = record.uiRevision
            record.renderDispatchedAt = current
            if record.priority == 'critical'
                and record.fallbackGeneration ~= record.presentationGeneration then
                if record.visibilityAckGeneration ~= record.presentationGeneration then
                    record.visibilityAckGeneration = record.presentationGeneration
                    record.visibilityAckDeadline = current
                        + (Limits.uiVisibilityAckTimeoutMs or 1250)
                end
                record.visibilityAckRevision = record.uiRevision
            else
                record.visibilityAckDeadline = nil
                record.visibilityAckRevision = nil
            end
        else
            metric('transport_failures')
            presented = criticalFallback(record, descriptor) or presented
        end
        if firstPresentation and delivered and record.sound and soundEnabled
            and presentationPreferences.soundVolume > 0
            and (not presentationPreferences.muteNonCriticalSounds
                or record.priority == 'critical')
            and current - lastSoundAt >= Limits.soundMinimumIntervalMs then
            lastSoundAt = current
            pcall(playSound, record.priority == 'critical' and 'critical'
                or record.tone, presentationPreferences.soundVolume)
        end
        if presented then record.presentedOnce = true end
        return accepted
    end

    local promote, synchronizeActionProjection

    local actionProjectionTokens = {}
    synchronizeActionProjection = function(current)
        local nextTokens, changed = {}, false
        for index = 1, Limits.maximumActions do
            local selected = selectedVisibleAction(index, current, false)
            nextTokens[index] = selected and selected.action.token or false
            if nextTokens[index] ~= (actionProjectionTokens[index] or false) then
                changed = true
            end
        end
        if not changed then return end
        actionProjectionTokens = nextTokens
        local rerender = {}
        for _, record in pairs(visible) do
            if record.lastRenderedRevision ~= nil then
                record.uiRevision = record.uiRevision + 1
                rerender[#rerender + 1] = record
            end
        end
        for _, record in ipairs(rerender) do
            render(record, current, true)
            record.lastRenderedAt = current
        end
    end

    local function finish(record, state, reason, current, requestedRevision, deferPromotion)
        if record.state == 'removed' then return end
        local wasVisible = record.state == 'visible'
        record.state = 'removed'
        visible[record.signalId] = nil
        uiVisibleRevisions[record.signalId] = nil
        removeFromArray(queue, record.signalId)
        records[record.signalId] = nil
        for sourceId in pairs(record.sourceRevisions or {}) do
            serverAliases[sourceId] = nil
        end
        clearDedupeIndex(record)
        clearGroupIndex(record)
        purgeActions(record)
        if wasVisible and record.lastRenderedRevision ~= nil then
            local removalRevision = math.max(record.uiRevision + 1,
                requestedRevision or 0)
            uiVisibilityConfirmed = false
            pcall(removeSignal, record.signalId, removalRevision)
        end
        appendHistory(record, state, reason, current)
        metric('removed')
        if not deferPromotion then promote(current) end
    end

    local function suspendServerPresentation(record, current)
        if record.authority ~= 'SERVER' or record.state == 'dormant'
            or record.state == 'removed' then return false end
        local wasVisible = record.state == 'visible'
        visible[record.signalId] = nil
        uiVisibleRevisions[record.signalId] = nil
        removeFromArray(queue, record.signalId)
        clearDedupeIndex(record)
        clearGroupIndex(record)
        purgeActions(record)
        record.state = 'dormant'
        record.visibleAt = nil
        record.expiresAt = nil
        record.pendingRenderAt = nil
        if wasVisible and record.lastRenderedRevision ~= nil then
            record.uiRevision = record.uiRevision + 1
            uiVisibilityConfirmed = false
            pcall(removeSignal, record.signalId, record.uiRevision)
        end
        record.lastRenderedRevision = nil
        metric('presentation_expired')
        return true
    end

    local function effectiveScore(record, current)
        local age = math.max(0, current - record.enqueuedAt)
        local score = (priorityWeight[record.priority] or 0)
            + math.floor(age / Limits.starvationStepMs) * 8
        if record.ownerResource ~= lastPromotedOwner then score = score + 6
        elseif consecutiveOwner > 1 then score = score - consecutiveOwner * 4 end
        return score
    end

    promote = function(current)
        while visibleCount() < visibleCapacity do
            local selected, selectedScore = nil, nil
            for _, signalId in ipairs(queue) do
                local candidate = records[signalId]
                local quietDeferred = candidate and presentationQuiet
                    and (candidate.priority == 'low' or candidate.priority == 'normal')
                if candidate and candidate.state == 'queued' and not quietDeferred then
                    local score = effectiveScore(candidate, current)
                    if selected == nil or score > selectedScore
                        or score == selectedScore and candidate.sequence < selected.sequence then
                        selected, selectedScore = candidate, score
                    end
                end
            end
            if selected == nil then break end
            removeFromArray(queue, selected.signalId)
            if selected.presentationDemoted then
                selected.uiRevision = selected.uiRevision + 1
                selected.presentationDemoted = nil
            end
            selected.state = 'visible'
            selected.visibleAt = current
            metric('queue_wait_ms', math.max(0, current - selected.enqueuedAt))
            metric('queue_promotions')
            if selected.durationMs ~= nil and selected.expiresAt == nil then
                selected.expiresAt = math.min(selected.hardExpiresAt,
                    current + selected.durationMs)
            end
            for _, action in ipairs(selected.actions or {}) do
                if selected.expiresAt ~= nil then
                    action.expiresAt = math.min(action.expiresAt, selected.expiresAt)
                end
            end
            visible[selected.signalId] = selected
            if lastPromotedOwner == selected.ownerResource then
                consecutiveOwner = consecutiveOwner + 1
            else
                lastPromotedOwner, consecutiveOwner = selected.ownerResource, 1
            end
            render(selected, current, true)
        end
        synchronizeActionProjection(current)
    end

    local function scheduleRender(record, current, coalesce)
        if record.state ~= 'visible' then return end
        if coalesce and record.lastRenderedAt ~= nil
            and current - record.lastRenderedAt < Limits.progressCoalesceMs then
            record.pendingRenderAt = record.lastRenderedAt + Limits.progressCoalesceMs
            metric('coalesced')
            return
        end
        render(record, current, true)
        record.lastRenderedAt = current
    end

    local function applyPresentationPlan(current)
        for _, record in pairs(records) do
            local resolved = resolvePosition(record.requestedPosition or record.position)
            local positionChanged = resolved ~= record.position
            record.position = resolved
            local quietDeferred = presentationQuiet
                and (record.priority == 'low' or record.priority == 'normal')
            if quietDeferred and record.state == 'visible' then
                record.uiRevision = record.uiRevision + 1
                uiVisibleRevisions[record.signalId] = nil
                if record.lastRenderedRevision ~= nil then
                    uiVisibilityConfirmed = false
                    pcall(removeSignal, record.signalId, record.uiRevision)
                end
                visible[record.signalId] = nil
                record.state = 'queued'
                record.enqueuedAt = current
                record.visibleAt = nil
                record.expiresAt = nil
                record.pendingRenderAt = nil
                record.lastRenderedRevision = nil
                record.presentationDemoted = true
                queue[#queue + 1] = record.signalId
                metric('quiet_deferred')
            elseif positionChanged and record.state == 'visible' then
                record.uiRevision = record.uiRevision + 1
                scheduleRender(record, current, false)
            end
        end
        promote(current)
    end

    local function resolveRecord(notificationId)
        local alias = serverAliases[notificationId]
        return alias and records[alias.recordId] or records[notificationId], alias
    end

    local function ownedRecord(handleValue)
        local handle, handleError = Validation.handle(handleValue)
        if not handle then return nil, handleError end
        local record = records[handle.notificationId]
        if not record then
            return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                'The notification no longer exists.')
        end
        if record.authority ~= 'LOCAL' or record.ownerResource ~= handle.ownerResource
            or record.ownerEpoch ~= handle.ownerEpoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification belongs to another owner incarnation.')
        end
        if record.localRevision ~= handle.revision then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The notification handle revision is stale.')
        end
        return record
    end

    local function refreshTimes(record, current)
        record.hardExpiresAt = record.createdAt + record.maxLifetimeMs
        if record.durationMs ~= nil and record.state == 'visible' then
            record.expiresAt = math.min(record.hardExpiresAt, current + record.durationMs)
        else
            record.expiresAt = nil
        end
    end

    local function applyContent(record, candidate, current, sourceId, sourceRevision,
        resetAggregateCount)
        clearGroupIndex(record)
        record.groupKey = candidate.groupKey
        record.kind = candidate.kind
        record.tone = candidate.tone
        record.priority = candidate.priority
        record.origin = candidate.origin
        record.title = candidate.title
        record.message = candidate.message
        record.iconKey = candidate.iconKey
        record.requestedPosition = candidate.position
        record.position = resolvePosition(record.requestedPosition)
        record.progress = Validation.copy(candidate.progress)
        record.requestedDurationMs = candidate.durationMs
        record.durationMs = effectiveDuration(candidate.durationMs,
            record.maxLifetimeMs or candidate.maxLifetimeMs)
        record.maxLifetimeMs = record.maxLifetimeMs or candidate.maxLifetimeMs
        record.maxRefreshCount = record.maxRefreshCount or candidate.maxRefreshCount
        record.history = candidate.history
        record.sound = candidate.sound == true
        if resetAggregateCount then
            -- Dedupe replace exchanges the complete presentation.
            record.count = candidate.count or 1
        elseif candidate.count ~= nil then
            record.count = candidate.count
        end
        if record.state == 'visible' and record.durationMs ~= nil then
            if candidate.progress
                and Limits.terminalProgressStates[candidate.progress.state] then
                record.expiresAt = math.min(record.hardExpiresAt,
                    current + record.durationMs)
            else
                record.expiresAt = math.min(record.hardExpiresAt,
                    (record.visibleAt or current) + record.durationMs)
            end
        elseif record.state == 'visible' then
            record.expiresAt = nil
        end
        installActions(record, candidate.actions, record.authority, sourceId, sourceRevision,
            current)
    end

    local function localPayloadAfterPatch(record, patch, current)
        local function selected(key)
            if patch[key] ~= nil then return Validation.copy(patch[key]) end
            return Validation.copy(record[key])
        end
        local payload = {
            kind = record.kind,
            tone = selected('tone'),
            priority = record.priority,
            title = selected('title'),
            position = selected('position'),
            maxLifetimeMs = record.maxLifetimeMs,
            history = record.history,
            sound = selected('sound') == true,
            origin = 'LOCAL',
            actions = {},
        }
        for _, key in ipairs({ 'message', 'iconKey', 'dedupeKey', 'dedupePolicy',
            'groupKey', 'maxRefreshCount', 'count', 'progress' }) do
            local value = selected(key)
            if value ~= nil then payload[key] = value end
        end
        local duration = patch.durationMs
        if duration == nil then duration = record.requestedDurationMs end
        if duration ~= nil then payload.durationMs = duration end
        if patch.actions ~= nil then
            payload.actions = Validation.copy(patch.actions)
        else
            for _, action in ipairs(record.actions or {}) do
                payload.actions[#payload.actions + 1] = {
                    id = action.id,
                    label = action.label,
                    hint = action.hint,
                    style = action.style,
                    ttlMs = math.max(Limits.minimumActionTtlMs,
                        math.min(Limits.maximumActionTtlMs,
                            math.floor(action.expiresAt - current))),
                }
            end
        end
        return payload
    end

    local function dedupeOrGroup(owner, epoch, authority, candidate, current)
        local index, entry, mode
        if candidate.dedupeKey then
            index = table.concat({ owner, tostring(epoch), authority,
                candidate.dedupeKey }, '\0d\0')
            entry = dedupe[index]
            mode = candidate.dedupePolicy or 'suppress'
            if entry and current - entry.at > Limits.dedupeWindowMs then
                if dedupe[index] == entry then dedupe[index] = nil end
                entry = nil
            end
            if entry then
                local existing = records[entry.recordId]
                if existing and existing.state ~= 'removed'
                    and existing.state ~= 'dormant' then
                    return existing, mode, index
                end
            end
        end
        if candidate.groupKey then
            index = table.concat({ owner, tostring(epoch), authority,
                candidate.groupKey, candidate.kind, candidate.tone,
                candidate.priority }, '\0g\0')
            entry = groups[index]
            mode = 'group'
            if entry and current - entry.at > Limits.groupingWindowMs then
                if groups[index] == entry then groups[index] = nil end
                entry = nil
            end
        end
        if not entry then return nil, mode, index end
        local existing = records[entry.recordId]
        if not existing or existing.state == 'removed' or existing.state == 'dormant' then
            return nil, mode, index
        end
        return existing, mode, index
    end

    local function evictionFor(candidate)
        if recordCount() < Limits.maximumQueue then return true, nil end
        local selected, dormant = nil, nil
        for _, record in pairs(records) do
            if record.state == 'dormant'
                and (dormant == nil or record.sequence < dormant.sequence) then
                dormant = record
            elseif record.state ~= 'removed'
                and (selected == nil
                    or priorityWeight[record.priority] < priorityWeight[selected.priority]
                    or priorityWeight[record.priority] == priorityWeight[selected.priority]
                        and record.sequence < selected.sequence) then
                selected = record
            end
        end
        if dormant ~= nil then return true, dormant end
        if selected == nil
            or priorityWeight[candidate.priority] <= priorityWeight[selected.priority] then
            return false, nil
        end
        return true, selected
    end

    local function burstAllowed(owner, candidate, current)
        local burst = bursts[owner]
        local count = burst and current - burst.startedAt <= Limits.burstWindowMs
            and burst.count or 0
        return count + 1 <= Limits.maximumBurst or candidate.dedupeKey ~= nil
            or candidate.groupKey ~= nil
    end

    local function commitBurst(owner, current)
        local burst = bursts[owner]
        if not burst or current - burst.startedAt > Limits.burstWindowMs then
            burst = { startedAt = current, count = 0 }
            bursts[owner] = burst
        end
        burst.count = burst.count + 1
    end

    local function commitEviction(record, current)
        if record == nil then return end
        if record.authority == 'SERVER' and record.state == 'dormant' then
            rememberServerTombstones(record, current)
        end
        finish(record, 'EVICTED', 'queue_evicted', current, nil, true)
        metric('queue_evictions')
    end

    local function createRecord(owner, epoch, candidate, authority, current,
        notificationId, sourceRevision, lifecycle)
        lifecycle = lifecycle or {}
        sequence = sequence + 1
        local record = {
            notificationId = notificationId,
            signalId = notificationId,
            ownerResource = owner,
            ownerEpoch = epoch,
            authority = authority,
            uiRevision = sourceRevision or 1,
            localRevision = authority == 'LOCAL' and 1 or nil,
            sequence = sequence,
            enqueuedAt = current,
            createdAt = lifecycle.createdAt or current,
            hardExpiresAt = lifecycle.hardExpiresAt
                or current + candidate.maxLifetimeMs,
            state = 'queued',
            count = candidate.count or 1,
            refreshCount = 0,
            sourceRevisions = {},
            actionGeneration = 0,
            actionProjectionGeneration = 0,
            presentationGeneration = 1,
            dedupeKey = candidate.dedupeKey,
            groupKey = candidate.groupKey,
        }
        applyContent(record, candidate, current, notificationId, sourceRevision)
        if record.progress and Limits.terminalProgressStates[record.progress.state] then
            record.requestedDurationMs = record.requestedDurationMs
                or Limits.terminalDurationMs
            record.durationMs = effectiveDuration(record.requestedDurationMs,
                record.maxLifetimeMs)
        end
        if authority == 'SERVER' then
            forgetServerTombstone(notificationId)
            record.sourceRevisions[notificationId] = sourceRevision
            serverAliases[notificationId] = {
                recordId = record.signalId,
                ownerResource = owner,
                ownerEpoch = epoch,
                revision = sourceRevision,
            }
        end
        records[record.signalId] = record
        queue[#queue + 1] = record.signalId
        if candidate.dedupeKey then
            reindexDedupe(record, current)
        end
        if candidate.groupKey then
            reindexGroup(record, current)
        end
        metric('created')
        promote(current)
        return record
    end

    local function mergeServerPresentation(existing, mode, index, owner, epoch,
        presentation, current)
        local notificationId = presentation.notificationId
        if index then
            local collection = mode == 'group' and groups or dedupe
            collection[index] = { recordId = existing.signalId, at = current }
        end
        if mode == 'refresh' and existing.maxRefreshCount == nil then
            existing.maxRefreshCount = presentation.maxRefreshCount
                or Limits.defaultMaxRefreshCount
        end
        existing.sourceRevisions[notificationId] = presentation.revision
        serverAliases[notificationId] = {
            recordId = existing.signalId, ownerResource = owner,
            ownerEpoch = epoch, revision = presentation.revision,
        }
        forgetServerTombstone(notificationId)
        local refreshCapped = mode == 'refresh'
            and (existing.refreshCount or 0) >= existing.maxRefreshCount
        if mode ~= 'suppress' and not refreshCapped then
            existing.presentationGeneration = existing.presentationGeneration + 1
            existing.uiRevision = math.max(existing.uiRevision + 1,
                presentation.revision)
            if mode == 'count' or mode == 'group' then
                existing.count = math.min(Limits.maximumCount,
                    (existing.count or 1) + 1)
                if mode == 'group' then
                    existing.title = presentation.title
                    existing.message = presentation.message
                    metric('grouped')
                end
            elseif mode == 'replace' then
                applyContent(existing, presentation, current, notificationId,
                    presentation.revision, true)
                reindexGroup(existing, current)
                applyPresentationPlan(current)
            elseif mode == 'refresh' then
                existing.refreshCount = (existing.refreshCount or 0) + 1
                refreshTimes(existing, current)
            end
            scheduleRender(existing, current, existing.kind == 'progress')
            synchronizeActionProjection(current)
        else
            metric('suppressed')
        end
        metric('deduplicated')
        return {
            notificationId = notificationId, ownerResource = owner,
            ownerEpoch = epoch, revision = presentation.revision,
        }
    end

    function engine.show(owner, epoch, candidate)
        if not active then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification engine is stopped.', true)
        end
        local resource, ownerError = Validation.resourceName(owner)
        if not resource or not Validation.isInteger(epoch, 1, MAXIMUM_SAFE_INTEGER) then
            return nil, ownerError or { code = 'NOTIFY_OWNER_STALE',
                message = 'The notification owner epoch is invalid.', retryable = false }
        end
        local acceptedEpoch, epochError = acceptOwnerEpoch(resource, epoch, 'LOCAL')
        if not acceptedEpoch then return nil, epochError end
        local current = now()
        local existing, mode, index = dedupeOrGroup(resource, epoch, 'LOCAL',
            candidate, current)
        local admissible, eviction = true, nil
        if not existing then admissible, eviction = evictionFor(candidate) end
        if not admissible then
            return Validation.failure('NOTIFY_QUEUE_FULL',
                'The bounded notification queue is full.', true)
        end
        if not burstAllowed(resource, candidate, current) then
            metric('rate_limited')
            metric('burst_rejected')
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its presentation budget.', true)
        end
        if not consumePresentation(resource, candidate, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its presentation budget.', true)
        end
        commitBurst(resource, current)
        if existing then
            if index then
                local collection = mode == 'group' and groups or dedupe
                collection[index] = { recordId = existing.signalId, at = current }
            end
            if mode == 'refresh' and existing.maxRefreshCount == nil then
                existing.maxRefreshCount = candidate.maxRefreshCount
                    or Limits.defaultMaxRefreshCount
            end
            if mode == 'suppress' then
                metric('suppressed')
                metric('deduplicated')
                return publicHandle(existing)
            end
            if mode == 'refresh'
                and (existing.refreshCount or 0) >= existing.maxRefreshCount then
                metric('suppressed')
                metric('deduplicated')
                return publicHandle(existing)
            end
            existing.localRevision = existing.localRevision + 1
            existing.presentationGeneration = existing.presentationGeneration + 1
            existing.uiRevision = math.max(existing.uiRevision + 1,
                existing.localRevision)
            if mode == 'count' or mode == 'group' then
                existing.count = math.min(Limits.maximumCount, (existing.count or 1) + 1)
                if mode == 'group' then
                    existing.title = candidate.title
                    existing.message = candidate.message
                    metric('grouped')
                else
                    metric('deduplicated')
                end
            elseif mode == 'replace' then
                applyContent(existing, candidate, current, nil, nil, true)
                reindexGroup(existing, current)
                applyPresentationPlan(current)
                metric('deduplicated')
            elseif mode == 'refresh' then
                existing.refreshCount = existing.refreshCount or 0
                existing.refreshCount = existing.refreshCount + 1
                refreshTimes(existing, current)
                metric('deduplicated')
            end
            scheduleRender(existing, current, existing.kind == 'progress')
            synchronizeActionProjection(current)
            return publicHandle(existing)
        end
        commitEviction(eviction, current)
        sequence = sequence + 1
        local id = ('local:%08x:%08x'):format(math.floor(epoch) & 0xffffffff,
            sequence & 0xffffffff)
        local record = createRecord(resource, epoch, candidate, 'LOCAL', current, id, 1)
        return publicHandle(record)
    end

    function engine.applyServer(owner, epoch, presentation, command)
        if not active or command ~= 'show' and command ~= 'update' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification server command is invalid.')
        end
        local resource, ownerError = Validation.resourceName(owner)
        if not resource or not Validation.isInteger(epoch, 1, MAXIMUM_SAFE_INTEGER) then
            return nil, ownerError or { code = 'NOTIFY_OWNER_STALE',
                message = 'The notification owner epoch is invalid.', retryable = false }
        end
        owner = resource
        local acceptedEpoch, epochError = acceptOwnerEpoch(owner, epoch, 'SERVER')
        if not acceptedEpoch then return nil, epochError end
        local current, notificationId = now(), presentation.notificationId
        pruneServerTombstones(current)
        if command == 'show' then
            if serverAliases[notificationId] or records[notificationId]
                or serverTombstones[notificationId] then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'The server notification already exists.')
            end
            local existing, mode, index = dedupeOrGroup(owner, epoch, presentation.origin,
                presentation, current)
            local admissible, eviction = true, nil
            if not existing then admissible, eviction = evictionFor(presentation) end
            if not admissible then
                return Validation.failure('NOTIFY_QUEUE_FULL',
                    'The bounded notification queue is full.', true)
            end
            if not burstAllowed(owner, presentation, current) then
                metric('rate_limited')
                metric('burst_rejected')
                return Validation.failure('NOTIFY_RATE_LIMITED',
                    'The notification owner exceeded its presentation budget.', true)
            end
            if not consumePresentation(owner, presentation, current) then
                return Validation.failure('NOTIFY_RATE_LIMITED',
                    'The notification owner exceeded its presentation budget.', true)
            end
            commitBurst(owner, current)
            if existing then
                return mergeServerPresentation(existing, mode, index, owner, epoch,
                    presentation, current)
            end
            commitEviction(eviction, current)
            createRecord(owner, epoch, presentation, 'SERVER', current,
                notificationId, presentation.revision)
            return {
                notificationId = notificationId, ownerResource = owner,
                ownerEpoch = epoch, revision = presentation.revision,
            }
        end
        local record, alias = resolveRecord(notificationId)
        if not record or not alias then
            local tombstone = serverTombstones[notificationId]
            if tombstone ~= nil then
                if tombstone.ownerResource ~= owner or tombstone.ownerEpoch ~= epoch
                    or tombstone.origin ~= presentation.origin then
                    return Validation.failure('NOTIFY_OWNER_STALE',
                        'The server notification owner incarnation is stale.')
                end
                if presentation.revision <= tombstone.revision then
                    return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                        'The server notification revision is stale.')
                end
                if current >= tombstone.hardExpiresAt then
                    forgetServerTombstone(notificationId)
                    return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                        'The server notification no longer exists.')
                end
                local existing, mode, index = dedupeOrGroup(owner, epoch,
                    presentation.origin,
                    presentation, current)
                local admissible, eviction = true, nil
                if not existing then admissible, eviction = evictionFor(presentation) end
                if not admissible then
                    return Validation.failure('NOTIFY_QUEUE_FULL',
                        'The bounded notification queue is full.', true)
                end
                if not consumeUpdate(owner, current) then
                    return Validation.failure('NOTIFY_RATE_LIMITED',
                        'The notification owner exceeded its update budget.', true)
                end
                if existing then
                    return mergeServerPresentation(existing, mode, index, owner, epoch,
                        presentation, current)
                end
                commitEviction(eviction, current)
                createRecord(owner, epoch, presentation, 'SERVER', current,
                    notificationId, presentation.revision, {
                        createdAt = tombstone.createdAt,
                        hardExpiresAt = tombstone.hardExpiresAt,
                    })
                return {
                    notificationId = notificationId, ownerResource = owner,
                    ownerEpoch = epoch, revision = presentation.revision,
                }
            end
            return Validation.failure('NOTIFY_NOTIFICATION_NOT_FOUND',
                'The server notification does not exist.')
        end
        if alias.ownerResource ~= owner or alias.ownerEpoch ~= epoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The server notification owner incarnation is stale.')
        end
        if record.origin ~= presentation.origin then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The server notification origin is immutable.')
        end
        if presentation.revision <= alias.revision then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The server notification revision is stale.')
        end
        local previousProgress = record.progress
        if previousProgress and presentation.progress then
            local transitions = progressTransitions[previousProgress.state]
            if not transitions or not transitions[presentation.progress.state] then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'The progress transition is stale or terminal.')
            end
            if previousProgress.mode == 'determinate'
                and presentation.progress.mode == 'determinate'
                and presentation.progress.state == 'RUNNING'
                and presentation.progress.value < previousProgress.value then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'Determinate progress cannot move backwards.')
            end
        end
        if not consumeUpdate(owner, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its update budget.', true)
        end
        alias.revision = presentation.revision
        record.sourceRevisions[notificationId] = presentation.revision
        record.presentationGeneration = record.presentationGeneration + 1
        record.uiRevision = math.max(record.uiRevision + 1, presentation.revision)
        local wasDormant = record.state == 'dormant'
        applyContent(record, presentation, current, notificationId, presentation.revision)
        if wasDormant then
            record.state = 'queued'
            record.enqueuedAt = current
            record.visibleAt = nil
            record.expiresAt = nil
            record.pendingRenderAt = nil
            queue[#queue + 1] = record.signalId
            reindexDedupe(record, current)
        end
        reindexGroup(record, current)
        if presentationQuiet
            and (record.priority == 'low' or record.priority == 'normal') then
            applyPresentationPlan(current)
        end
        if presentation.progress
            and Limits.terminalProgressStates[presentation.progress.state] then
            record.requestedDurationMs = presentation.durationMs
                or Limits.terminalDurationMs
            record.durationMs = effectiveDuration(record.requestedDurationMs,
                record.maxLifetimeMs)
            record.expiresAt = math.min(record.hardExpiresAt,
                current + record.durationMs)
        end
        if wasDormant then
            promote(current)
        else
            scheduleRender(record, current, presentation.kind == 'progress'
                and not Limits.terminalProgressStates[presentation.progress.state])
            synchronizeActionProjection(current)
        end
        return {
            notificationId = notificationId, ownerResource = owner,
            ownerEpoch = epoch, revision = presentation.revision,
        }
    end

    function engine.update(handleValue, patch)
        local record, recordError = ownedRecord(handleValue)
        if not record then return nil, recordError end
        local current = now()
        if patch.progress then
            if record.kind ~= 'progress' or record.progress == nil then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'Only progress notifications accept progress updates.')
            end
            local transitions = progressTransitions[record.progress.state]
            if not transitions or not transitions[patch.progress.state] then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'The progress transition is stale or terminal.')
            end
            if record.progress.mode == 'determinate' and patch.progress.mode == 'determinate'
                and patch.progress.state == 'RUNNING'
                and patch.progress.value < record.progress.value then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'Determinate progress cannot move backwards.')
            end
        end
        local payloadBytes, payloadError = Validation.payloadBytes(
            localPayloadAfterPatch(record, patch, current))
        if payloadBytes == nil then return nil, payloadError end
        if not consumeUpdate(record.ownerResource, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its update budget.', true)
        end
        record.localRevision = record.localRevision + 1
        record.presentationGeneration = record.presentationGeneration + 1
        record.uiRevision = math.max(record.uiRevision + 1, record.localRevision)
        for key, value in pairs(patch) do
            if key == 'position' then
                record.requestedPosition = value
                record.position = resolvePosition(value)
            elseif key == 'durationMs' then
                record.requestedDurationMs = value
                record.durationMs = effectiveDuration(value, record.maxLifetimeMs)
            elseif key ~= 'actions' then
                record[key] = Validation.copy(value)
            end
        end
        if patch.tone ~= nil then reindexGroup(record, current) end
        if patch.actions then
            installActions(record, patch.actions, 'LOCAL', record.notificationId,
                record.localRevision, current)
        else
            for _, action in ipairs(record.actions) do
                action.sourceRevision = record.localRevision
            end
        end
        if patch.durationMs then
            if record.state == 'visible' then
                record.expiresAt = math.min(record.hardExpiresAt,
                    (record.visibleAt or current) + record.durationMs)
            else
                record.expiresAt = nil
            end
        end
        if patch.progress and Limits.terminalProgressStates[patch.progress.state] then
            record.requestedDurationMs = patch.durationMs
                or Limits.terminalDurationMs
            record.durationMs = effectiveDuration(record.requestedDurationMs,
                record.maxLifetimeMs)
            record.expiresAt = math.min(record.hardExpiresAt,
                current + record.durationMs)
        end
        for _, action in ipairs(record.actions or {}) do
            if record.expiresAt ~= nil then
                action.expiresAt = math.min(action.expiresAt, record.expiresAt)
            end
        end
        scheduleRender(record, current, record.kind == 'progress'
            and patch.progress ~= nil
            and not Limits.terminalProgressStates[patch.progress.state])
        synchronizeActionProjection(current)
        return publicHandle(record)
    end

    function engine.complete(handleValue, state, message)
        local record, recordError = ownedRecord(handleValue)
        if not record then return nil, recordError end
        if record.kind ~= 'progress' or not Limits.terminalProgressStates[state] then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification cannot enter the requested terminal progress state.')
        end
        local patch = {
            progress = { state = state, mode = record.progress.mode },
        }
        if record.progress.mode == 'determinate' then
            patch.progress.value = record.progress.value
            patch.progress.maximum = record.progress.maximum
        end
        if message ~= nil then patch.message = message end
        if state == 'SUCCESS' then patch.tone = 'success'; patch.iconKey = 'success'
        elseif state == 'FAILED' then patch.tone = 'danger'; patch.iconKey = 'error'
        else patch.tone = 'neutral'; patch.iconKey = 'close' end
        local normalized, patchError = Validation.notificationPatch(patch, {
            authority = 'CLIENT', kind = 'progress',
        })
        if not normalized then return nil, patchError end
        return engine.update(handleValue, normalized)
    end

    function engine.dismiss(handleValue, reason)
        local record, recordError = ownedRecord(handleValue)
        if not record then return nil, recordError end
        reason = reason or 'dismissed'
        if not Limits.dismissReasons[reason] then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification dismissal reason is invalid.')
        end
        local current = now()
        if not consumeUpdate(record.ownerResource, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its update budget.', true)
        end
        record.localRevision = record.localRevision + 1
        record.uiRevision = math.max(record.uiRevision + 1, record.localRevision)
        local notificationId = record.notificationId
        finish(record, reason == 'cancelled' and 'CANCELLED' or 'DISMISSED',
            reason, current, record.uiRevision)
        return { notificationId = notificationId, dismissed = true }
    end

    function engine.dismissServer(owner, epoch, notificationId, revision, reason)
        local record, alias = resolveRecord(notificationId)
        if not record or not alias then
            local tombstone = serverTombstones[notificationId]
            if tombstone == nil then return true end
            if tombstone.ownerResource ~= owner or tombstone.ownerEpoch ~= epoch then
                return Validation.failure('NOTIFY_OWNER_STALE',
                    'The server notification owner incarnation is stale.')
            end
            if revision <= tombstone.revision then
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'The server dismissal revision is stale.')
            end
            forgetServerTombstone(notificationId)
            return true
        end
        if alias.ownerResource ~= owner or alias.ownerEpoch ~= epoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The server notification owner incarnation is stale.')
        end
        if revision <= alias.revision then
            return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                'The server dismissal revision is stale.')
        end
        local current = now()
        if not consumeUpdate(owner, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'The notification owner exceeded its update budget.', true)
        end
        record.sourceRevisions[notificationId] = nil
        serverAliases[notificationId] = nil
        purgeActions(record, notificationId)
        local members = 0
        for _ in pairs(record.sourceRevisions) do members = members + 1 end
        if members > 0 then
            record.count = math.max(1, math.min(record.count or members, members))
            record.uiRevision = record.uiRevision + 1
            scheduleRender(record, current, false)
            synchronizeActionProjection(current)
        else
            finish(record, reason == 'cancelled' and 'CANCELLED' or 'DISMISSED',
                reason or 'dismissed', current, revision)
        end
        return true
    end

    function engine.onAction(handleValue, actionId, callback)
        local record, recordError = ownedRecord(handleValue)
        if not record then return nil, recordError end
        if type(actionId) ~= 'string' or not isCallable(callback) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'A local notification action id and callback are required.')
        end
        for _, action in ipairs(record.actions) do
            if action.authority == 'LOCAL' and action.id == actionId then
                action.callback = callback
                return true
            end
        end
        return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
            'The local notification action does not exist.')
    end

    function engine.invokeAction(token)
        local action = actionTokens[token]
        if not action then
            return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                'The notification action no longer exists.')
        end
        if action.used then
            metric('action_replayed')
            return Validation.failure('NOTIFY_ACTION_REPLAYED',
                'The notification action was already used.')
        end
        local current = now()
        if current >= action.expiresAt then
            actionTokens[token] = nil
            action.used = true
            local expiredRecord = select(1, resolveRecord(action.sourceNotificationId))
            if expiredRecord and expiredRecord.state == 'visible' then
                expiredRecord.uiRevision = expiredRecord.uiRevision + 1
                scheduleRender(expiredRecord, current, false)
                synchronizeActionProjection(current)
            end
            metric('action_expired')
            return Validation.failure('NOTIFY_ACTION_EXPIRED',
                'The notification action expired.')
        end
        local record = select(1, resolveRecord(action.sourceNotificationId))
        if not record or record.state ~= 'visible'
            or record.lastRenderedRevision ~= record.uiRevision then
            return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                'The notification action is no longer visible.')
        end
        if current - lastActionInvokeAt < Limits.actionMinimumIntervalMs then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'Notification actions are temporarily rate limited.', true)
        end
        if not consumeBudget('\0action', {
            { name = 'action', global = true, cost = 1 },
        }, current) then
            return Validation.failure('NOTIFY_RATE_LIMITED',
                'Notification actions are temporarily rate limited.', true)
        end
        lastActionInvokeAt = current
        action.used = true
        local result, actionError
        if action.authority == 'SERVER' then
            result, actionError = invokeServerAction(action.token,
                action.sourceNotificationId, action.sourceRevision)
        elseif isCallable(action.callback) then
            local invoked
            invoked, result, actionError = pcall(action.callback, {
                notificationId = record.notificationId,
                actionId = action.id,
                revision = record.localRevision,
            })
            if not invoked then
                result, actionError = nil, { code = 'NOTIFY_UNAVAILABLE',
                    message = 'The local notification action failed.', retryable = false }
            end
        else
            result, actionError = Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                'The local notification action has no handler.')
        end
        record.uiRevision = record.uiRevision + 1
        scheduleRender(record, current, false)
        synchronizeActionProjection(current)
        metric('actions')
        if result == nil or result == false then return nil, actionError end
        return result
    end

    function engine.invokeVisibleAction(index)
        if not Validation.isInteger(index, 1, Limits.maximumActions) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification action index is invalid.')
        end
        local current = now()
        local selected = selectedVisibleAction(index, current, true)
        if not selected then
            return Validation.failure('NOTIFY_ACTION_NOT_FOUND',
                'No visible notification exposes that action.')
        end
        return engine.invokeAction(selected.action.token)
    end

    function engine.setPresentationContext(owner, epoch, value)
        if not active then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification engine is stopped.', true)
        end
        local resource, ownerError = Validation.resourceName(owner)
        if not resource or not Validation.isInteger(epoch, 1, MAXIMUM_SAFE_INTEGER) then
            return nil, ownerError or { code = 'NOTIFY_OWNER_STALE',
                message = 'The presentation context owner epoch is invalid.',
                retryable = false }
        end
        local acceptedEpoch, epochError = acceptOwnerEpoch(resource, epoch, 'LOCAL')
        if not acceptedEpoch then return nil, epochError end
        local context, contextError = canonicalPresentationContext(value)
        if not context then return nil, contextError end
        local key = table.concat({ resource, tostring(epoch), context.contextId }, '\0c\0')
        if presentationContexts[key] == nil
            and presentationPlan.contextCount >= MAXIMUM_PRESENTATION_CONTEXTS then
            return Validation.failure('NOTIFY_CONTEXT_LIMIT',
                'The bounded presentation context registry is full.', true)
        end
        context.ownerResource = resource
        context.ownerEpoch = epoch
        presentationContexts[key] = context
        rebuildPresentationPlan()
        applyPresentationPlan(now())
        metric('context_updates')
        return Validation.copy(context)
    end

    function engine.clearPresentationContext(owner, epoch, contextId)
        local resource, ownerError = Validation.resourceName(owner)
        if not resource or not Validation.isInteger(epoch, 1, MAXIMUM_SAFE_INTEGER) then
            return nil, ownerError or { code = 'NOTIFY_OWNER_STALE',
                message = 'The presentation context owner epoch is invalid.',
                retryable = false }
        end
        if type(contextId) ~= 'string' or #contextId < 1
            or #contextId > MAXIMUM_CONTEXT_ID_BYTES
            or contextId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The presentation context id is invalid.')
        end
        local key = table.concat({ resource, tostring(epoch), contextId }, '\0c\0')
        local cleared = presentationContexts[key] ~= nil
        if cleared then
            presentationContexts[key] = nil
            rebuildPresentationPlan()
            applyPresentationPlan(now())
            metric('context_updates')
        end
        return { cleared = cleared }
    end

    function engine.setVisibleCapacity(value)
        if not Validation.isInteger(value, 1, Limits.maximumVisible) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The visible notification capacity is invalid.')
        end
        if value == visibleCapacity then return { visibleCapacity = visibleCapacity } end
        local current = now()
        visibleCapacity = value
        if visibleCount() > visibleCapacity then
            local ordered = {}
            for _, record in pairs(visible) do ordered[#ordered + 1] = record end
            table.sort(ordered, function(left, right)
                local priority = (priorityWeight[left.priority] or 0)
                    - (priorityWeight[right.priority] or 0)
                if priority ~= 0 then return priority > 0 end
                if left.createdAt ~= right.createdAt then
                    return left.createdAt > right.createdAt
                end
                if left.uiRevision ~= right.uiRevision then
                    return left.uiRevision > right.uiRevision
                end
                return left.signalId < right.signalId
            end)
            for index = visibleCapacity + 1, #ordered do
                local record = ordered[index]
                record.uiRevision = record.uiRevision + 1
                uiVisibleRevisions[record.signalId] = nil
                if record.lastRenderedRevision ~= nil then
                    uiVisibilityConfirmed = false
                    pcall(removeSignal, record.signalId, record.uiRevision)
                end
                visible[record.signalId] = nil
                record.state = 'queued'
                record.enqueuedAt = current
                record.visibleAt = nil
                record.expiresAt = nil
                record.pendingRenderAt = nil
                record.lastRenderedRevision = nil
                record.visibilityAckDeadline = nil
                record.visibilityAckRevision = nil
                record.renderAckRevision = nil
                record.renderDispatchedAt = nil
                record.presentationDemoted = true
                queue[#queue + 1] = record.signalId
            end
        end
        promote(current)
        return { visibleCapacity = visibleCapacity }
    end

    function engine.setUiPreferences(value)
        if not Validation.exactObject(value, {
            schemaVersion = true, quality = true, scale = true, density = true,
            reducedMotion = true, reducedTransparency = true, highContrast = true,
        }) or value.schemaVersion ~= nil and value.schemaVersion ~= 1
            or value.quality ~= nil and value.quality ~= 'LOW'
                and value.quality ~= 'BALANCED' and value.quality ~= 'HIGH'
                and value.quality ~= 'ULTRA'
            or value.scale ~= nil and value.scale ~= 85 and value.scale ~= 100
                and value.scale ~= 115 and value.scale ~= 125
            or value.density ~= nil and value.density ~= 'compact'
                and value.density ~= 'comfortable'
            or value.reducedMotion ~= nil and type(value.reducedMotion) ~= 'boolean'
            or value.reducedTransparency ~= nil
                and type(value.reducedTransparency) ~= 'boolean'
            or value.highContrast ~= nil and type(value.highContrast) ~= 'boolean' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The UI presentation preferences are invalid.')
        end
        local reducedMotion = uiPreferences.reducedMotion
        local reducedTransparency = uiPreferences.reducedTransparency
        local highContrast = uiPreferences.highContrast
        if value.reducedMotion ~= nil then reducedMotion = value.reducedMotion end
        if value.reducedTransparency ~= nil then
            reducedTransparency = value.reducedTransparency
        end
        if value.highContrast ~= nil then highContrast = value.highContrast end
        uiPreferences = {
            scale = value.scale or uiPreferences.scale,
            reducedMotion = reducedMotion,
            reducedTransparency = reducedTransparency,
            highContrast = highContrast,
        }
        return Validation.copy(uiPreferences)
    end

    function engine.setPresentationPreferences(value)
        if not Validation.exactObject(value, {
            position = true, durationScale = true, soundEnabled = true,
            soundVolume = true, muteNonCriticalSounds = true, history = true,
        }) or value.position ~= nil and value.position ~= 'auto'
                and not Limits.positions[value.position]
            or value.durationScale ~= nil and not Validation.isInteger(
                value.durationScale, Limits.minimumDurationScale,
                Limits.maximumDurationScale)
            or value.soundEnabled ~= nil and type(value.soundEnabled) ~= 'boolean'
            or value.soundVolume ~= nil and not Validation.isInteger(value.soundVolume,
                Limits.minimumSoundVolume, Limits.maximumSoundVolume)
            or value.muteNonCriticalSounds ~= nil
                and type(value.muteNonCriticalSounds) ~= 'boolean'
            or value.history ~= nil and type(value.history) ~= 'boolean' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification presentation preferences are invalid.')
        end
        local previousPosition = presentationPreferences.position
        for key, candidate in pairs(value) do
            presentationPreferences[key] = candidate
        end
        soundEnabled = presentationPreferences.soundEnabled
        if previousPosition ~= presentationPreferences.position then
            applyPresentationPlan(now())
        end
        return Validation.copy(presentationPreferences)
    end

    function engine.presentationSnapshot()
        local preferences = Validation.copy(uiPreferences)
        for key, value in pairs(presentationPreferences) do preferences[key] = value end
        return {
            quiet = presentationPlan.quiet,
            contextCount = presentationPlan.contextCount,
            reservedPositions = Validation.copy(presentationPlan.reservedPositions),
            preferredPosition = presentationPlan.preferredPosition,
            fallbackPositions = Validation.copy(presentationPlan.fallbackPositions),
            preferences = preferences,
        }
    end

    function engine.ownerStop(owner, maximumEpoch, authority)
        local current, removing = now(), {}
        for _, record in pairs(records) do
            if record.ownerResource == owner
                and (maximumEpoch == nil or record.ownerEpoch <= maximumEpoch)
                and (authority == nil or record.authority == authority) then
                removing[#removing + 1] = record
            end
        end
        for _, record in ipairs(removing) do
            finish(record, 'OWNER_STOPPED', 'owner_stopped', current, nil, true)
        end
        if authority == nil or authority == 'SERVER' then
            local tombstones = {}
            for notificationId, tombstone in pairs(serverTombstones) do
                if tombstone.ownerResource == owner
                    and (maximumEpoch == nil or tombstone.ownerEpoch <= maximumEpoch) then
                    tombstones[#tombstones + 1] = notificationId
                end
            end
            for _, notificationId in ipairs(tombstones) do
                forgetServerTombstone(notificationId)
            end
        end
        local contextChanged = false
        if authority == nil or authority == 'LOCAL' then
            for key, context in pairs(presentationContexts) do
                if context.ownerResource == owner
                    and (maximumEpoch == nil or context.ownerEpoch <= maximumEpoch) then
                    presentationContexts[key] = nil
                    contextChanged = true
                end
            end
        end
        if contextChanged then
            rebuildPresentationPlan()
            applyPresentationPlan(current)
        else
            promote(current)
        end
        local newerEpoch = false
        for _, epochAuthority in ipairs({ 'LOCAL', 'SERVER' }) do
            if (authority == nil or authority == epochAuthority)
                and maximumEpoch ~= nil
                and (latestOwnerEpoch[ownerEpochKey(owner, epochAuthority)] or 0)
                    > maximumEpoch then
                newerEpoch = true
            end
        end
        local survivingAuthority = false
        if authority ~= nil then
            for _, record in pairs(records) do
                if record.ownerResource == owner and record.authority ~= authority then
                    survivingAuthority = true
                    break
                end
            end
            if not survivingAuthority and authority ~= 'SERVER' then
                for _, tombstone in pairs(serverTombstones) do
                    if tombstone.ownerResource == owner then
                        survivingAuthority = true
                        break
                    end
                end
            end
            if not survivingAuthority and authority ~= 'LOCAL' then
                for _, context in pairs(presentationContexts) do
                    if context.ownerResource == owner then
                        survivingAuthority = true
                        break
                    end
                end
            end
            local otherAuthority = authority == 'LOCAL' and 'SERVER' or 'LOCAL'
            if latestOwnerEpoch[ownerEpochKey(owner, otherAuthority)] ~= nil then
                survivingAuthority = true
            end
        end
        if not newerEpoch and not survivingAuthority then
            local budgetPrefix = owner .. '\0'
            for key in pairs(budgetBuckets) do
                if key:sub(1, #budgetPrefix) == budgetPrefix then budgetBuckets[key] = nil end
            end
            bursts[owner] = nil
        end
        if not newerEpoch then
            if authority == nil then
                latestOwnerEpoch[ownerEpochKey(owner, 'LOCAL')] = nil
                latestOwnerEpoch[ownerEpochKey(owner, 'SERVER')] = nil
            else
                latestOwnerEpoch[ownerEpochKey(owner, authority)] = nil
            end
        end
        metric('owner_cleanup', #removing)
        return { removed = #removing, contextsCleared = contextChanged }
    end

    function engine.resetServerSession()
        local current, removing = now(), {}
        for _, record in pairs(records) do
            if record.authority == 'SERVER' then removing[#removing + 1] = record end
        end
        for _, record in ipairs(removing) do
            finish(record, 'CANCELLED', 'session_changed', current, nil, true)
        end
        serverTombstones, serverTombstoneOrder, serverTombstoneCount = {}, {}, 0
        promote(current)
        return { removed = #removing }
    end

    function engine.tick()
        if not active then return nil end
        local current, expired, dormant = now(), {}, {}
        pruneServerTombstones(current)
        for _, record in pairs(records) do
            if record.visibilityAckDeadline ~= nil
                and current >= record.visibilityAckDeadline then
                record.visibilityAckDeadline = nil
                metric('visibility_ack_timeouts')
                metric('transport_failures')
                criticalFallback(record, signalDescriptor(record, current))
            end
            if current >= record.hardExpiresAt then
                expired[#expired + 1] = record
            elseif record.expiresAt ~= nil and current >= record.expiresAt then
                if record.authority == 'SERVER' then
                    dormant[#dormant + 1] = record
                else
                    expired[#expired + 1] = record
                end
            elseif record.pendingRenderAt ~= nil and current >= record.pendingRenderAt then
                render(record, current, true)
                record.lastRenderedAt = current
            else
                local actionsChanged = false
                for _, action in ipairs(record.actions or {}) do
                    if not action.used and current >= action.expiresAt then
                        action.used = true
                        actionTokens[action.token] = nil
                        actionsChanged = true
                        metric('action_expired')
                    end
                end
                if actionsChanged then
                    record.uiRevision = record.uiRevision + 1
                    scheduleRender(record, current, false)
                end
            end
        end
        for _, record in ipairs(dormant) do suspendServerPresentation(record, current) end
        for _, record in ipairs(expired) do
            finish(record, 'EXPIRED', 'expired', current, nil, true)
        end
        promote(current)
        return engine.nextDeadline()
    end

    function engine.nextDeadline()
        if not active then return nil end
        local deadline = nil
        for _, record in pairs(records) do
            deadline = deadline and math.min(deadline, record.hardExpiresAt)
                or record.hardExpiresAt
            if record.expiresAt ~= nil then deadline = math.min(deadline, record.expiresAt) end
            if record.pendingRenderAt ~= nil then
                deadline = math.min(deadline, record.pendingRenderAt)
            end
            if record.visibilityAckDeadline ~= nil then
                deadline = math.min(deadline, record.visibilityAckDeadline)
            end
            for _, action in ipairs(record.actions or {}) do
                if not action.used then deadline = math.min(deadline, action.expiresAt) end
            end
        end
        for _, tombstone in pairs(serverTombstones) do
            deadline = deadline and math.min(deadline, tombstone.hardExpiresAt)
                or tombstone.hardExpiresAt
        end
        return deadline
    end

    function engine.reconcile(snapshot)
        local current, remote = now(), {}
        if type(snapshot) == 'table' and snapshot.visibleCapacity ~= nil then
            local configured, capacityError = engine.setVisibleCapacity(snapshot.visibleCapacity)
            if not configured then return nil, capacityError end
        end
        if type(snapshot) == 'table' and type(snapshot.signals) == 'table' then
            for _, signal in ipairs(snapshot.signals) do
                if type(signal) == 'table' and type(signal.signalId) == 'string'
                    and Validation.isInteger(signal.revision, 1, MAXIMUM_SAFE_INTEGER) then
                    remote[signal.signalId] = signal.revision
                end
            end
        end
        for signalId, record in pairs(visible) do
            local remoteRevision = remote[signalId]
            if remoteRevision == nil or remoteRevision < record.uiRevision then
                render(record, current, true)
            elseif remoteRevision > record.uiRevision then
                record.uiRevision = remoteRevision + 1
                render(record, current, true)
            else
                record.lastRenderedRevision = remoteRevision
            end
            remote[signalId] = nil
        end
        for signalId, revision in pairs(remote) do
            pcall(removeSignal, signalId, revision + 1)
        end
        return true
    end

    function engine.confirmVisibility(snapshot)
        local confirmed = {}
        if type(snapshot) ~= 'table' or type(snapshot.signals) ~= 'table'
            or not Validation.isInteger(snapshot.generation, 0, MAXIMUM_SAFE_INTEGER)
            or not Validation.isInteger(snapshot.visibilityRevision, 1,
                MAXIMUM_SAFE_INTEGER)
            or snapshot.visibleCapacity ~= nil
                and (not Validation.isInteger(snapshot.visibleCapacity, 1,
                    Limits.maximumVisible) or snapshot.visibleCapacity ~= visibleCapacity)
            or snapshot.visibilityCapacity ~= nil
                and (not Validation.isInteger(snapshot.visibilityCapacity, 1,
                    Limits.maximumVisible) or snapshot.visibilityCapacity ~= visibleCapacity)
            or snapshot.visibilityGeneration ~= snapshot.generation then
            uiVisibleRevisions = {}
            uiVisibilityConfirmed = false
            return Validation.failure('NOTIFY_UI_UNAVAILABLE',
                'The UI visibility acknowledgement is unavailable.', true)
        end
        local count = Validation.arrayLength(snapshot.signals, Limits.maximumQueue)
        if count == nil then
            uiVisibleRevisions = {}
            uiVisibilityConfirmed = false
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The UI visibility acknowledgement is invalid.')
        end
        for index = 1, count do
            local signal = snapshot.signals[index]
            if type(signal) ~= 'table' or type(signal.signalId) ~= 'string'
                or not Validation.isInteger(signal.revision, 1, MAXIMUM_SAFE_INTEGER)
                or type(signal.visible) ~= 'boolean' then
                uiVisibleRevisions = {}
                uiVisibilityConfirmed = false
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'A UI visibility acknowledgement entry is invalid.')
            end
            local record = records[signal.signalId]
            if signal.visible and (record == nil or record.state ~= 'visible'
                or signal.revision > record.uiRevision
                or confirmed[signal.signalId] ~= nil) then
                uiVisibleRevisions = {}
                uiVisibilityConfirmed = false
                return Validation.failure('NOTIFY_NOTIFICATION_STALE',
                    'A UI visibility acknowledgement entry is stale.')
            end
            if signal.visible then confirmed[signal.signalId] = signal.revision end
        end
        local current = now()
        uiVisibleRevisions = confirmed
        uiVisibilityConfirmed = true
        for signalId, confirmedRevision in pairs(confirmed) do
            local record = visible[signalId]
            if record ~= nil and confirmedRevision == record.uiRevision then
                if record.renderAckRevision == confirmedRevision
                    and record.renderDispatchedAt ~= nil then
                    metric('render_ack_samples')
                    metric('render_ack_time_ms', math.max(0,
                        current - record.renderDispatchedAt))
                    record.renderAckRevision = nil
                    record.renderDispatchedAt = nil
                end
                if record.visibilityAckRevision == confirmedRevision then
                    record.visibilityAckDeadline = nil
                    record.visibilityAckRevision = nil
                end
                record.actionProjectionGeneration = record.actionGeneration or 0
            end
        end
        synchronizeActionProjection(current)
        return true
    end

    function engine.visibilityReady()
        return uiVisibilityConfirmed
    end

    function engine.resetUiVisibility()
        uiVisibleRevisions = {}
        uiVisibilityConfirmed = false
        local current = now()
        for _, record in pairs(visible) do
            if record.priority == 'critical'
                and record.fallbackGeneration ~= record.presentationGeneration then
                record.visibilityAckGeneration = record.presentationGeneration
                record.visibilityAckRevision = record.uiRevision
                record.visibilityAckDeadline = current
                    + (Limits.uiVisibilityAckTimeoutMs or 1250)
            end
        end
        synchronizeActionProjection(current)
        return true
    end

    function engine.history(owner, limit)
        local maximum = math.max(1, math.min(tonumber(limit) or 32,
            Limits.maximumHistory))
        local result = {}
        for index = #history, 1, -1 do
            local entry = history[index]
            if owner == nil or entry.ownerResource == owner then
                result[#result + 1] = Validation.copy(entry)
                if #result >= maximum then break end
            end
        end
        return result
    end

    function engine.snapshot()
        local budgetCount = 0
        local pendingVisibilityAcks = 0
        for _ in pairs(budgetBuckets) do budgetCount = budgetCount + 1 end
        for _, record in pairs(records) do
            if record.visibilityAckDeadline ~= nil then
                pendingVisibilityAcks = pendingVisibilityAcks + 1
            end
        end
        return {
            active = active,
            queued = #queue,
            visible = visibleCount(),
            visibleCapacity = visibleCapacity,
            records = recordCount(),
            actionTokens = (function()
                local count = 0
                for _ in pairs(actionTokens) do count = count + 1 end
                return count
            end)(),
            serverTombstones = serverTombstoneCount,
            uiVisibilityConfirmed = uiVisibilityConfirmed,
            pendingVisibilityAcks = pendingVisibilityAcks,
            history = #history,
            soundEnabled = soundEnabled,
            budgetBuckets = budgetCount,
            presentation = engine.presentationSnapshot(),
        }
    end

    function engine.setSoundEnabled(enabled)
        if type(enabled) ~= 'boolean' then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification sound preference must be a boolean.')
        end
        soundEnabled = enabled
        presentationPreferences.soundEnabled = enabled
        return { soundEnabled = soundEnabled }
    end

    function engine.shutdown()
        if not active then return true end
        local current, removing = now(), {}
        for _, record in pairs(records) do removing[#removing + 1] = record end
        active = false
        for _, record in ipairs(removing) do
            finish(record, 'CANCELLED', 'owner_stopped', current, nil, true)
        end
        presentationContexts = {}
        uiVisibleRevisions = {}
        uiVisibilityConfirmed = false
        latestOwnerEpoch = {}
        serverTombstones, serverTombstoneOrder, serverTombstoneCount = {}, {}, 0
        rebuildPresentationPlan()
        return true
    end

    return engine
end
