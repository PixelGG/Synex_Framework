SynexInteractIntent = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation,
    'interact validation must be loaded first')

local DEFAULT_WEIGHTS = {
    basePriority = 0.30,
    specificity = 0.16,
    gaze = 0.34,
    distance = 0.28,
    slotAlignment = 0.12,
    exactRay = 0.12,
    continuity = Limits.intentContinuityBonus,
    recentHistory = 0.03,
    movementPenalty = 0.10,
    unknownConditionPenalty = 0.08,
    ambiguityPenalty = 0.04,
}

local HISTORY_RETENTION_MS = 5000
local MAXIMUM_HISTORY = 16
local MAXIMUM_REPLAY_FRAMES = math.min(64, Limits.maximumTraceFrames)
local MAXIMUM_EVALUATOR_CACHE_ENTRIES = 32
local MAXIMUM_RUNNING_EVALUATORS = 16
local DEFAULT_EVALUATOR_CACHE_TTL_MS = 250
local MINIMUM_EVALUATOR_RETRY_MS = 50
local REJECTION_REASON_ORDER = {
    'TOO_FAR', 'OCCLUDED', 'WRONG_ACTOR_STATE', 'TARGET_STATE',
    'SLOT_BUSY', 'SLOT_DISABLED', 'SLOT_MISMATCH', 'CONDITION_FALSE',
    'CONDITION_UNKNOWN',
}
local ADVISORY_REASON_ORDER = { 'CONDITION_UNKNOWN', 'AMBIGUOUS' }
local AVAILABLE_TARGET_STATES = { ACTIVE = true, AVAILABLE = true }
local BUSY_SLOT_STATES = { RESERVED = true, OCCUPIED = true }

local function failure(code, message)
    local _, value = Validation.failure(code, message)
    return value
end

local function copy(value)
    return Validation.copy(value)
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function signature(item)
    return item.intent.key .. '|' .. item.candidate.id
end

local function emptyDecision()
    return {
        evaluated = 0, accepted = 0, rejected = 0,
        viablePrimaryCount = 0, ambiguous = false,
        rejectionReasons = {}, advisories = {},
    }
end

local function reasonItems(counts, order)
    local values = {}
    for _, code in ipairs(order) do
        local count = counts[code]
        if count and count > 0 then values[#values + 1] = { code = code, count = count } end
    end
    return values
end

local function resolvePath(root, path)
    if type(path) ~= 'string' or #path < 1 or #path > 128 then return nil, false end
    local current, depth = root, 0
    for segment in path:gmatch('[^.]+') do
        depth = depth + 1
        if depth > 8 or segment:match('^[A-Za-z][A-Za-z0-9_]*$') == nil
            or not Validation.isPlainTable(current) then return nil, false end
        current = rawget(current, segment)
        if current == nil then return nil, true end
    end
    return current, depth > 0
end

local function contains(container, expected)
    if type(container) == 'string' and type(expected) == 'string' then
        return container:find(expected, 1, true) ~= nil
    end
    if not Validation.isPlainTable(container) then return nil end
    local length = rawlen(container)
    for index = 1, length do
        if rawget(container, index) == expected then return true end
    end
    return false
end

local function declarativeConditionResult(condition, environment)
    if not Validation.isPlainTable(condition) or condition.kind ~= 'declarative' then
        return nil
    end
    local actual, pathValid = resolvePath(environment, condition.path)
    if not pathValid then return nil end
    local operator, expected = condition.operator, condition.value
    if operator == 'truthy' then return not not actual end
    if operator == 'falsy' then return not actual end
    if operator == 'eq' then return actual == expected end
    if operator == 'ne' then return actual ~= expected end
    if operator == 'contains' then return contains(actual, expected) end
    if type(actual) ~= 'number' or type(expected) ~= 'number'
        or not Validation.isFinite(actual) or not Validation.isFinite(expected) then return nil end
    if operator == 'lt' then return actual < expected end
    if operator == 'lte' then return actual <= expected end
    if operator == 'gt' then return actual > expected end
    if operator == 'gte' then return actual >= expected end
    return nil
end

function SynexInteractIntent.create(options)
    options = options or {}
    local now = assert(options.now, 'intent engine requires monotonic time')
    local spawn = options.spawn or function(handler) handler() end
    local observe = options.observe or function() end
    local weights = copy(DEFAULT_WEIGHTS)
    if type(options.weights) == 'table' then
        for key, value in pairs(options.weights) do
            if weights[key] ~= nil and Validation.isFinite(value)
                and value >= 0 and value <= 2 then weights[key] = value + 0.0 end
        end
    end
    local switchThreshold = Validation.isFinite(options.switchThreshold)
        and clamp(options.switchThreshold, 0, 1) or Limits.intentSwitchThreshold
    local minimumDwellMs = Validation.isInteger(options.minimumDwellMs, 0, 2000)
        and options.minimumDwellMs or Limits.intentMinimumDwellMs
    local active, current, challenger, ranked = true, nil, nil, {}
    local lastDecision = emptyDecision()
    local assistEnabled = false
    local history = {}
    local serial = 0
    local evaluators, evaluatorCount, runningEvaluatorCalls = {}, 0, 0
    local evaluatorStats = {
        invocations = 0, failures = 0, timeouts = 0,
        durationMs = 0, durationSamples = 0,
    }
    local engine = {}

    local function recentHistoryBonus(key, currentTime)
        for index = #history, 1, -1 do
            local entry = history[index]
            if currentTime - entry.at > HISTORY_RETENTION_MS then
                table.remove(history, index)
            elseif entry.key == key then return weights.recentHistory end
        end
        return 0
    end

    local function record(item, reason, currentTime)
        serial = serial + 1
        history[#history + 1] = {
            serial = serial, at = currentTime,
            key = item and item.intent.key or 'none',
            candidateId = item and item.candidate.id or nil,
            reason = reason,
        }
        while #history > MAXIMUM_HISTORY do table.remove(history, 1) end
        observe('intentChanges', 1)
    end

    local function timeoutEvaluator(record, entry, timestamp)
        if entry.timedOut then return end
        entry.timedOut, entry.hasResult = true, false
        entry.nextAttemptAt = timestamp
            + math.max(MINIMUM_EVALUATOR_RETRY_MS, record.cacheTtlMs)
        evaluatorStats.timeouts = evaluatorStats.timeouts + 1
        evaluatorStats.failures = evaluatorStats.failures + 1
    end

    local function customConditionResult(condition, environment, candidate, intent,
        conditionIndex, currentTime)
        local record = evaluators[condition.evaluator]
        if not record or type(candidate.id) ~= 'string' or type(intent.key) ~= 'string'
            or condition.arguments ~= nil
                and not Validation.isPlainTable(condition.arguments) then
            return nil
        end
        local cacheKey = candidate.id .. '\0' .. intent.key .. '\0' .. tostring(conditionIndex)
        local entry = record.cache[cacheKey]
        if entry and entry.running and not entry.timedOut
            and currentTime >= entry.deadlineAt then
            timeoutEvaluator(record, entry, currentTime)
        end
        if entry and entry.hasResult
            and currentTime - entry.resultAt <= record.cacheTtlMs then
            entry.lastUsedAt = currentTime
            return entry.result
        end
        if entry and (entry.running or currentTime < (entry.nextAttemptAt or 0)) then
            entry.lastUsedAt = currentTime
            return nil
        end
        if entry == nil then
            local cacheCount, oldestKey, oldestAt = 0, nil, math.huge
            for key, cached in pairs(record.cache) do
                cacheCount = cacheCount + 1
                local lastUsedAt = cached.lastUsedAt or 0
                if lastUsedAt < oldestAt then oldestKey, oldestAt = key, lastUsedAt end
            end
            if cacheCount >= MAXIMUM_EVALUATOR_CACHE_ENTRIES and oldestKey ~= nil then
                record.cache[oldestKey] = nil
            end
            entry = {
                generation = 0, running = false, timedOut = false,
                hasResult = false, resultAt = 0, lastUsedAt = currentTime,
                nextAttemptAt = 0,
            }
            record.cache[cacheKey] = entry
        end
        if runningEvaluatorCalls >= MAXIMUM_RUNNING_EVALUATORS then return nil end
        local invocationContext = copy(environment)
        local invocationArguments = copy(condition.arguments or {})
        if invocationContext == nil or invocationArguments == nil then
            entry.nextAttemptAt = currentTime
                + math.max(MINIMUM_EVALUATOR_RETRY_MS, record.cacheTtlMs)
            evaluatorStats.failures = evaluatorStats.failures + 1
            return nil
        end
        entry.generation = entry.generation + 1
        local generation, startedAt = entry.generation, currentTime
        entry.running, entry.timedOut, entry.hasResult = true, false, false
        entry.deadlineAt = startedAt + record.timeoutMs
        entry.lastUsedAt = currentTime
        runningEvaluatorCalls = runningEvaluatorCalls + 1
        evaluatorStats.invocations = evaluatorStats.invocations + 1
        local invocation = function()
            local invoked, result = pcall(record.handler, {
                schemaVersion = 1, authority = 'OBSERVED', phase = 'VISIBILITY',
                context = invocationContext, arguments = invocationArguments,
            })
            local finishedAt = now()
            runningEvaluatorCalls = math.max(0, runningEvaluatorCalls - 1)
            evaluatorStats.durationMs = evaluatorStats.durationMs
                + math.max(0, finishedAt - startedAt)
            evaluatorStats.durationSamples = evaluatorStats.durationSamples + 1
            if evaluators[record.key] ~= record or record.cache[cacheKey] ~= entry
                or entry.generation ~= generation then return end
            entry.running = false
            if finishedAt - startedAt > record.timeoutMs then
                timeoutEvaluator(record, entry, finishedAt)
                return
            end
            if not invoked or type(result) ~= 'boolean' then
                entry.hasResult = false
                entry.nextAttemptAt = finishedAt
                    + math.max(MINIMUM_EVALUATOR_RETRY_MS, record.cacheTtlMs)
                evaluatorStats.failures = evaluatorStats.failures + 1
                return
            end
            entry.result, entry.hasResult, entry.resultAt = result, true, finishedAt
            entry.nextAttemptAt = finishedAt + record.cacheTtlMs
        end
        local scheduled = pcall(spawn, invocation)
        if not scheduled then
            entry.running = false
            runningEvaluatorCalls = math.max(0, runningEvaluatorCalls - 1)
            entry.nextAttemptAt = currentTime
                + math.max(MINIMUM_EVALUATOR_RETRY_MS, record.cacheTtlMs)
            evaluatorStats.failures = evaluatorStats.failures + 1
            return nil
        end
        if entry.hasResult and currentTime - entry.resultAt <= record.cacheTtlMs then
            return entry.result
        end
        return nil
    end

    local function evaluate(context, candidate, intent, currentTime, candidateIntentCount)
        if context.actor.dead or context.actor.ragdoll then
            return nil, 'WRONG_ACTOR_STATE'
        end
        if candidate.occluded == true then return nil, 'OCCLUDED' end
        local targetState = candidate.targetState
        if targetState == nil and Validation.isPlainTable(candidate.target) then
            targetState = rawget(candidate.target, 'state')
        end
        if targetState ~= nil and not AVAILABLE_TARGET_STATES[targetState] then
            return nil, 'TARGET_STATE'
        end
        local slotState = candidate.slotState
        if slotState == nil and Validation.isPlainTable(candidate.slot) then
            slotState = rawget(candidate.slot, 'state') or rawget(candidate.slot, 'initialState')
        end
        if slotState == 'DISABLED' then return nil, 'SLOT_DISABLED' end
        if BUSY_SLOT_STATES[slotState] then return nil, 'SLOT_BUSY' end
        local radius = tonumber(candidate.slot and candidate.slot.interactionRadius)
            or Limits.maximumAuthorityDistance
        if candidate.distance > radius then return nil, 'TOO_FAR' end
        if intent.slotSelector ~= nil and intent.slotSelector ~= candidate.slotKey then
            return nil, 'SLOT_MISMATCH'
        end
        local environment = {
            actor = context.actor,
            camera = context.camera,
            world = context.worldContext,
            target = candidate.target,
            candidate = {
                distance = candidate.distance,
                gaze = candidate.gaze,
                exactRay = candidate.exactRay,
                slotAlignment = candidate.slotAlignment,
                facingDelta = candidate.facingDelta,
                source = candidate.source,
                slotKey = candidate.slotKey,
                objectKey = candidate.objectKey,
                tags = candidate.objectTags,
            },
            inputDevice = context.inputDevice,
        }
        local unknownConditions = 0
        for conditionIndex, condition in ipairs(intent.visibilityConditions or {}) do
            local accepted
            if condition.kind == 'evaluator' then
                accepted = customConditionResult(condition, environment, candidate, intent,
                    conditionIndex, currentTime)
                if accepted == nil then return nil, 'CONDITION_UNKNOWN' end
            else accepted = declarativeConditionResult(condition, environment) end
            if accepted == false then return nil, 'CONDITION_FALSE' end
            if accepted == nil then unknownConditions = unknownConditions + 1 end
        end
        local base = clamp(intent.basePriority / 100.0, -1.0, 1.0)
            * weights.basePriority
        local specificity = clamp(intent.specificity / 100.0, -1.0, 1.0)
            * weights.specificity
        local gaze = clamp(candidate.gaze or 0, 0, 1) * weights.gaze
        local distance = (1.0 - clamp(candidate.distance / radius, 0, 1))
            * weights.distance
        local slotAlignment = clamp(candidate.slotAlignment or 0, 0, 1)
            * weights.slotAlignment
        local exactRay = candidate.exactRay and weights.exactRay or 0
        local continuity = current and current.intent.key == intent.key
            and current.candidate.id == candidate.id and weights.continuity or 0
        local recent = recentHistoryBonus(intent.key, currentTime)
        local movement = clamp((context.actor.speed or 0) / 8.0, 0, 1)
            * weights.movementPenalty
        local unknown = math.min(1, unknownConditions)
            * weights.unknownConditionPenalty
        local ambiguity = math.max(0, candidateIntentCount - 1)
            * weights.ambiguityPenalty / math.max(1, candidateIntentCount)
        local score = base + specificity + gaze + distance + slotAlignment
            + exactRay + continuity + recent - movement - unknown - ambiguity
        return {
            score = score,
            breakdown = {
                base = base, specificity = specificity, gaze = gaze,
                distance = distance, slot = slotAlignment, exactRay = exactRay,
                continuity = continuity, history = recent,
                movementPenalty = -movement,
                unknownConditionPenalty = -unknown,
                ambiguityPenalty = -ambiguity,
            },
            unknownConditions = unknownConditions,
        }
    end

    local function deterministicOrder(left, right)
        if left.score ~= right.score then return left.score > right.score end
        if left.intent.specificity ~= right.intent.specificity then
            return left.intent.specificity > right.intent.specificity
        end
        if left.intent.basePriority ~= right.intent.basePriority then
            return left.intent.basePriority > right.intent.basePriority
        end
        if left.intent.key ~= right.intent.key then return left.intent.key < right.intent.key end
        return left.candidate.id < right.candidate.id
    end

    local function rank(context, candidates, currentTime)
        local values, rejected, advisories = {}, {}, {}
        local decision = emptyDecision()
        for _, candidate in ipairs(candidates or {}) do
            local intents = candidate.intents or {}
            for _, intent in ipairs(intents) do
                decision.evaluated = decision.evaluated + 1
                local scoring, rejection = evaluate(context, candidate, intent,
                    currentTime, #intents)
                if scoring then
                    decision.accepted = decision.accepted + 1
                    if scoring.unknownConditions > 0 then
                        advisories.CONDITION_UNKNOWN = (advisories.CONDITION_UNKNOWN or 0)
                            + scoring.unknownConditions
                    end
                    values[#values + 1] = {
                        intent = intent, candidate = candidate,
                        score = scoring.score, breakdown = scoring.breakdown,
                        unknownConditions = scoring.unknownConditions,
                    }
                else
                    decision.rejected = decision.rejected + 1
                    rejected[rejection] = (rejected[rejection] or 0) + 1
                end
            end
        end
        table.sort(values, deterministicOrder)
        local firstPrimaryScore, secondPrimaryScore
        for _, item in ipairs(values) do
            if item.intent.trigger == 'primary' then
                decision.viablePrimaryCount = decision.viablePrimaryCount + 1
                if firstPrimaryScore == nil then firstPrimaryScore = item.score
                elseif secondPrimaryScore == nil then secondPrimaryScore = item.score end
            end
        end
        if secondPrimaryScore ~= nil
            and firstPrimaryScore - secondPrimaryScore <= switchThreshold then
            decision.ambiguous = true
            advisories.AMBIGUOUS = 1
        end
        decision.rejectionReasons = reasonItems(rejected, REJECTION_REASON_ORDER)
        decision.advisories = reasonItems(advisories, ADVISORY_REASON_ORDER)
        return values, decision
    end

    local function publicItem(item)
        if not item then return nil end
        return {
            key = item.intent.key,
            revision = item.intent.revision,
            verb = item.intent.verb,
            label = item.intent.label,
            icon = item.intent.icon,
            trigger = item.intent.trigger,
            slotKey = item.candidate.slotKey,
            score = item.score,
            breakdown = copy(item.breakdown),
            target = copy(item.candidate.target),
            position = copy(item.candidate.position),
            candidateId = item.candidate.id,
            objectKey = item.candidate.objectKey,
            objectRevision = item.candidate.objectRevision,
            distance = item.candidate.distance,
            cancelPolicy = copy(item.intent.cancelPolicy) or {},
            presentation = copy(item.intent.presentation) or {},
            objectPresentation = copy(item.candidate.presentation) or {},
            source = item.candidate.source,
            exactRay = item.candidate.exactRay == true,
            unknownConditions = item.unknownConditions,
        }
    end

    function engine.arbitrate(context, candidates)
        if not active or type(context) ~= 'table' then
            return nil, {}, failure('INTERACT_CONTEXT_INVALID',
                'Intent arbitration requires an observed context.')
        end
        local started = now()
        ranked, lastDecision = rank(context, candidates, started)
        local best
        for _, candidate in ipairs(ranked) do
            if candidate.intent.trigger == 'primary' then best = candidate; break end
        end
        if not best then
            if current then record(nil, 'invalidated', started) end
            current, challenger = nil, nil
            observe('intentScoringDurationMs', math.max(0, now() - started))
            return nil, {}, nil
        end
        local currentRanked
        if current then
            local currentSignature = signature(current)
            for _, item in ipairs(ranked) do
                if signature(item) == currentSignature then currentRanked = item; break end
            end
        end
        if not currentRanked then
            current, challenger = best, nil
            record(current, 'acquired', started)
        elseif signature(best) == signature(currentRanked) then
            current, challenger = currentRanked, nil
        elseif best.score <= currentRanked.score + switchThreshold then
            current, challenger = currentRanked, nil
        else
            local bestSignature = signature(best)
            if not challenger or challenger.signature ~= bestSignature then
                challenger = { signature = bestSignature, since = started }
                current = currentRanked
            elseif started - challenger.since >= (assistEnabled
                and math.max(minimumDwellMs, Limits.intentAssistMinimumDwellMs)
                or minimumDwellMs) then
                current, challenger = best, nil
                record(current, 'hysteresis_switch', started)
            else current = currentRanked end
        end
        local alternatives, selectedSignature = {}, signature(current)
        for _, item in ipairs(ranked) do
            if signature(item) ~= selectedSignature then
                alternatives[#alternatives + 1] = publicItem(item)
                if #alternatives >= Limits.maximumVisibleIntents - 1 then break end
            end
        end
        observe('intentScoringDurationMs', math.max(0, now() - started))
        return publicItem(current), alternatives, nil
    end

    function engine.resolve(intentKey, candidateId, revision)
        if type(intentKey) ~= 'string' then return nil end
        for _, item in ipairs(ranked) do
            if item.intent.key == intentKey
                and (candidateId == nil or item.candidate.id == candidateId)
                and (revision == nil or item.intent.revision == revision) then
                return publicItem(item)
            end
        end
    end

    function engine.current()
        return publicItem(current)
    end

    function engine.setInteractionAssist(enabled)
        if type(enabled) ~= 'boolean' then
            return nil, failure('INTERACT_CONTEXT_INVALID',
                'Interaction Assist must be a boolean preference.')
        end
        if assistEnabled ~= enabled then challenger = nil end
        assistEnabled = enabled
        return true, nil
    end

    function engine.registerEvaluator(owner, epoch, definition, handler)
        if not active or not Validation.resourceName(owner)
            or not Validation.isInteger(epoch, 1)
            or not Validation.exactObject(definition, { 'key' }, {
                'timeoutMs', 'cacheTtlMs',
            })
            or not Validation.identifier(definition.key)
            or definition.key:sub(1, #owner + 1) ~= owner .. ':'
            or definition.timeoutMs ~= nil
                and not Validation.isInteger(definition.timeoutMs, 1, 1000)
            or definition.cacheTtlMs ~= nil
                and not Validation.isInteger(definition.cacheTtlMs, 0, 5000)
            or not Validation.isCallable(handler) then
            return nil, failure('INTERACT_EVALUATOR_INVALID',
                'The client condition evaluator registration is invalid.')
        end
        if evaluators[definition.key] or evaluatorCount >= Limits.maximumEvaluators then
            return nil, failure('INTERACT_EVALUATOR_CONFLICT',
                'The client condition evaluator key or capacity conflicts.')
        end
        local record = {
            key = definition.key, owner = owner, epoch = epoch, handler = handler,
            timeoutMs = definition.timeoutMs or Limits.evaluatorTimeoutMs,
            cacheTtlMs = definition.cacheTtlMs == nil
                and DEFAULT_EVALUATOR_CACHE_TTL_MS or definition.cacheTtlMs,
            cache = {},
        }
        evaluators[record.key], evaluatorCount = record, evaluatorCount + 1
        return {
            key = record.key,
            unregister = function()
                if evaluators[record.key] ~= record then return false end
                evaluators[record.key] = nil
                evaluatorCount = evaluatorCount - 1
                record.cache = {}
                return true
            end,
        }, nil
    end

    function engine.cleanupOwner(owner, epoch)
        local removed = 0
        for key, record in pairs(evaluators) do
            if record.owner == owner and (epoch == nil or record.epoch == epoch) then
                evaluators[key] = nil
                evaluatorCount = evaluatorCount - 1
                record.cache = {}
                removed = removed + 1
            end
        end
        return removed
    end

    function engine.reset(reason)
        if current then record(nil, reason or 'reset', now()) end
        current, challenger, ranked = nil, nil, {}
        lastDecision = emptyDecision()
    end

    function engine.snapshot()
        local values = {}
        for index = 1, math.min(#ranked, Limits.maximumVisibleIntents) do
            values[index] = publicItem(ranked[index])
        end
        return {
            active = active, current = publicItem(current), ranked = values,
            challenger = challenger and copy(challenger) or nil,
            history = copy(history), weights = copy(weights),
            switchThreshold = switchThreshold, minimumDwellMs = minimumDwellMs,
            effectiveMinimumDwellMs = assistEnabled
                and math.max(minimumDwellMs, Limits.intentAssistMinimumDwellMs)
                or minimumDwellMs,
            interactionAssist = assistEnabled,
            decision = copy(lastDecision),
        }
    end

    function engine.diagnostics()
        local values = {}
        for index = 1, math.min(#ranked, Limits.maximumVisibleIntents) do
            local item = ranked[index]
            values[index] = {
                intentKey = item.intent.key, trigger = item.intent.trigger,
                score = item.score, breakdown = copy(item.breakdown),
                unknownConditions = item.unknownConditions,
            }
        end
        local changes = {}
        for index, entry in ipairs(history) do
            changes[index] = {
                serial = entry.serial, at = entry.at,
                intentKey = entry.key, reason = entry.reason,
            }
        end
        local cacheEntries, timedOutEntries = 0, 0
        for _, evaluator in pairs(evaluators) do
            for _, entry in pairs(evaluator.cache) do
                cacheEntries = cacheEntries + 1
                if entry.timedOut then timedOutEntries = timedOutEntries + 1 end
            end
        end
        return {
            active = active,
            current = current and {
                intentKey = current.intent.key, trigger = current.intent.trigger,
                score = current.score,
            } or nil,
            ranked = values,
            challenger = challenger and { pending = true, since = challenger.since } or nil,
            history = changes, weights = copy(weights),
            switchThreshold = switchThreshold, minimumDwellMs = minimumDwellMs,
            effectiveMinimumDwellMs = assistEnabled
                and math.max(minimumDwellMs, Limits.intentAssistMinimumDwellMs)
                or minimumDwellMs,
            interactionAssist = assistEnabled,
            decision = copy(lastDecision),
            evaluators = {
                registered = evaluatorCount, inFlight = runningEvaluatorCalls,
                cacheEntries = cacheEntries, timedOutEntries = timedOutEntries,
                invocations = evaluatorStats.invocations,
                failures = evaluatorStats.failures, timeouts = evaluatorStats.timeouts,
                averageDurationMs = evaluatorStats.durationSamples > 0
                    and evaluatorStats.durationMs / evaluatorStats.durationSamples or 0,
            },
        }
    end

    function engine.cleanup()
        active = false
        current, challenger, ranked, history = nil, nil, {}, {}
        evaluators, evaluatorCount = {}, 0
        lastDecision = emptyDecision()
    end

    return engine
end

function SynexInteractIntent.replay(frames, options)
    options = options or {}
    if not Validation.exactObject(options, {}, {
        'weights', 'switchThreshold', 'minimumDwellMs', 'interactionAssist',
    })
        or options.weights ~= nil and not Validation.isPlainTable(options.weights)
        or options.switchThreshold ~= nil and not Validation.isFinite(options.switchThreshold)
        or options.minimumDwellMs ~= nil
            and not Validation.isInteger(options.minimumDwellMs, 0, 2000)
        or options.interactionAssist ~= nil
            and type(options.interactionAssist) ~= 'boolean' then
        return nil, failure('INTERACT_REPLAY_INVALID',
            'Intent replay options are invalid.')
    end
    local admitted = Validation.array(frames, MAXIMUM_REPLAY_FRAMES)
    if not admitted then return nil, failure('INTERACT_REPLAY_INVALID',
        'Intent replay requires a bounded frame array.') end
    local clock, previousAt = 0, -1
    local replayOptions = {
        now = function() return clock end,
        switchThreshold = options.switchThreshold,
        minimumDwellMs = options.minimumDwellMs,
    }
    if options.weights ~= nil then
        local copiedWeights, weightsCopy = pcall(copy, options.weights)
        if not copiedWeights or weightsCopy == nil then
            return nil, failure('INTERACT_REPLAY_INVALID',
            'Intent replay weights are invalid.') end
        replayOptions.weights = weightsCopy
    end
    local isolated = SynexInteractIntent.create(replayOptions)
    if options.interactionAssist ~= nil then
        isolated.setInteractionAssist(options.interactionAssist)
    end
    local results = {}
    for index, frame in ipairs(admitted) do
        if not Validation.exactObject(frame, { 'context', 'candidates' }, { 'at' })
            or not Validation.isPlainTable(frame.context)
            or not Validation.array(frame.candidates, Limits.maximumCandidateBatch)
            or frame.at ~= nil and not Validation.isInteger(frame.at, 0) then
            isolated.cleanup()
            return nil, failure('INTERACT_REPLAY_INVALID',
                'Intent replay contains an invalid frame.')
        end
        clock = frame.at == nil and previousAt + 1 or frame.at
        if clock < previousAt then
            isolated.cleanup()
            return nil, failure('INTERACT_REPLAY_INVALID',
                'Intent replay timestamps must be monotonic.')
        end
        previousAt = clock
        local copied, context, candidates = pcall(function()
            return copy(frame.context), copy(frame.candidates)
        end)
        if not copied or context == nil or candidates == nil then
            isolated.cleanup()
            return nil, failure('INTERACT_REPLAY_INVALID',
                'Intent replay contains an invalid container.')
        end
        local executed, primary, alternatives, replayError = pcall(
            isolated.arbitrate, context, candidates)
        if not executed or replayError then
            isolated.cleanup()
            return nil, failure('INTERACT_REPLAY_INVALID',
                'Intent replay arbitration failed.')
        end
        local alternativeKeys = {}
        for alternativeIndex, alternative in ipairs(alternatives or {}) do
            if alternativeIndex > Limits.maximumVisibleIntents - 1 then break end
            alternativeKeys[alternativeIndex] = alternative.key
        end
        results[index] = {
            frame = index, at = clock,
            primary = primary and {
                intentKey = primary.key, trigger = primary.trigger,
                score = primary.score,
            } or nil,
            alternativeIntentKeys = alternativeKeys,
            decision = isolated.diagnostics().decision,
        }
    end
    isolated.cleanup()
    return results, nil
end
