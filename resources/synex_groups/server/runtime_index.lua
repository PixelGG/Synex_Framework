return function(Foundation)
local ONLINE_MEMBERSHIP_STATES = {
    PROBATION = true,
    ACTIVE = true,
    SUSPENDED = true,
    LEAVE = true,
    INACTIVE = true
}

local MEMBERSHIP_REFRESH_ACTIONS = {
    ['membership.activated'] = true,
    ['membership.draft'] = true,
    ['membership.invited'] = true,
    ['membership.applicant'] = true,
    ['membership.under_review'] = true,
    ['membership.approved'] = true,
    ['membership.probation'] = true,
    ['membership.visibility_changed'] = true,
    ['membership.suspended'] = true,
    ['membership.leave'] = true,
    ['membership.inactive'] = true,
    ['membership.terminated'] = true,
    ['membership.banned'] = true,
    ['membership.left'] = true,
    ['membership.archived'] = true
}

local GROUP_INVALIDATION_ACTIONS = {
    ['group.archived'] = true,
    ['group.deleted'] = true,
    ['group.dissolving'] = true
}

local function createRuntimeIndex(options)
    options = options or {}
    local function boundedInteger(value, fallback, minimum, maximum)
        local candidate = tonumber(value)
        if not candidate or math.type(candidate) ~= 'integer' then candidate = fallback end
        return math.max(minimum, math.min(candidate, maximum))
    end
    local maximumCharacters = boundedInteger(
        options.maximumCharacters, 4096, 16, 8192)
    local maximumMemberships = boundedInteger(
        options.maximumMemberships, 131072, 64, 262144)
    local maximumMembershipsPerCharacter = boundedInteger(
        options.maximumMembershipsPerCharacter, 1024, 1, 4096)
    local counters = {
        hits = 0,
        misses = 0,
        loads = 0,
        unloads = 0,
        rebuilds = 0,
        refreshes = 0,
        refreshFailures = 0,
        invalidations = 0,
        clears = 0
    }

    local function emptyState()
        return {
            byCharacter = {},
            membershipOwner = {},
            onlineByGroup = {},
            dutyByMembership = {},
            dutyBySession = {},
            dutyByGroup = {},
            characterCount = 0,
            membershipCount = 0,
            dutySessionCount = 0,
            onlineGroupCount = 0,
            dutyGroupCount = 0
        }
    end

    local state = emptyState()

    local function invalid(message, details)
        return Foundation.domainError('RUNTIME_INDEX_INVALID', message, false, details)
    end

    local function capacity(message, details)
        return Foundation.domainError(
            'RUNTIME_INDEX_CAPACITY_EXCEEDED', message, false, details)
    end

    local function validStateKey(value)
        return type(value) == 'string' and #value >= 2 and #value <= 48
            and value:match('^[a-z][a-z0-9_.:%-]*$') ~= nil
    end

    local function arraySize(value, maximum)
        if type(value) ~= 'table' then return nil, false end
        local count, highest = 0, 0
        for key in next, value do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
                return nil, false
            end
            count = count + 1
            highest = math.max(highest, key)
            if count > maximum then return count, true end
        end
        if highest ~= count then return nil, false end
        return count, true
    end

    local function copyMembership(entry)
        return {
            membershipId = entry.membershipId,
            groupId = entry.groupId,
            characterId = entry.characterId,
            lifecycleState = entry.lifecycleState
        }
    end

    local function copyDuty(entry)
        return {
            sessionId = entry.sessionId,
            membershipId = entry.membershipId,
            groupId = entry.groupId,
            characterId = entry.characterId,
            state = entry.state,
            countsAsOnDuty = entry.countsAsOnDuty,
            assignmentId = entry.assignmentId,
            version = entry.version
        }
    end

    local function normalizeContext(characterId, context)
        if not Foundation.isSubjectId(characterId) then
            return nil, invalid('The runtime character identifier is invalid.')
        end
        if type(context) ~= 'table' or context.characterId ~= characterId then
            return nil, invalid('The runtime character context is invalid.')
        end
        local membershipCount, membershipsAreArray = arraySize(
            context.memberships, maximumMembershipsPerCharacter)
        if not membershipsAreArray then
            return nil, invalid('Runtime memberships must be a contiguous bounded array.')
        end
        if membershipCount > maximumMembershipsPerCharacter then
            return nil, capacity('The character runtime context exceeds its membership bound.', {
                characterId = characterId,
                maximum = maximumMembershipsPerCharacter
            })
        end
        local normalized = { characterId = characterId, memberships = {} }
        local seenMemberships, seenSessions = {}, {}
        for index, candidate in ipairs(context.memberships) do
            if type(candidate) ~= 'table'
                or candidate.characterId ~= characterId
                or not Foundation.isPublicId(candidate.membershipId)
                or not Foundation.isPublicId(candidate.groupId)
                or ONLINE_MEMBERSHIP_STATES[candidate.lifecycleState] ~= true then
                return nil, invalid('A runtime membership row is invalid.', {
                    characterId = characterId,
                    index = index
                })
            end
            if seenMemberships[candidate.membershipId] then
                return nil, invalid('A runtime character context contains a duplicate membership.', {
                    characterId = characterId,
                    membershipId = candidate.membershipId
                })
            end
            seenMemberships[candidate.membershipId] = true
            local membership = {
                membershipId = candidate.membershipId,
                groupId = candidate.groupId,
                characterId = characterId,
                lifecycleState = candidate.lifecycleState
            }
            if candidate.dutySession ~= nil then
                local duty = candidate.dutySession
                if type(duty) ~= 'table'
                    or candidate.lifecycleState ~= 'ACTIVE'
                    or not Foundation.isPublicId(duty.sessionId)
                    or not validStateKey(duty.state)
                    or type(duty.countsAsOnDuty) ~= 'boolean'
                    or (duty.assignmentId ~= nil
                        and not Foundation.isPublicId(duty.assignmentId))
                    or type(duty.version) ~= 'number'
                    or math.type(duty.version) ~= 'integer' or duty.version < 1 then
                    return nil, invalid('An open runtime duty session is invalid.', {
                        characterId = characterId,
                        membershipId = candidate.membershipId
                    })
                end
                if seenSessions[duty.sessionId] then
                    return nil, invalid('A runtime character context contains a duplicate duty session.', {
                        characterId = characterId,
                        sessionId = duty.sessionId
                    })
                end
                seenSessions[duty.sessionId] = true
                membership.dutySession = {
                    sessionId = duty.sessionId,
                    membershipId = membership.membershipId,
                    groupId = membership.groupId,
                    characterId = characterId,
                    state = duty.state,
                    countsAsOnDuty = duty.countsAsOnDuty,
                    assignmentId = duty.assignmentId,
                    version = duty.version
                }
            end
            normalized.memberships[#normalized.memberships + 1] = membership
        end
        return normalized, nil
    end

    local function removeMembership(target, membershipId)
        local membership = target.membershipOwner[membershipId]
        if not membership then return false end
        local character = target.byCharacter[membership.characterId]
        if character then
            character.memberships[membershipId] = nil
            character.count = math.max(0, character.count - 1)
        end
        local onlineGroup = target.onlineByGroup[membership.groupId]
        if onlineGroup then
            onlineGroup.items[membershipId] = nil
            onlineGroup.count = math.max(0, onlineGroup.count - 1)
            if onlineGroup.count == 0 then
                target.onlineByGroup[membership.groupId] = nil
                target.onlineGroupCount = math.max(0, target.onlineGroupCount - 1)
            end
        end
        local duty = target.dutyByMembership[membershipId]
        if duty then
            target.dutyByMembership[membershipId] = nil
            target.dutyBySession[duty.sessionId] = nil
            target.dutySessionCount = math.max(0, target.dutySessionCount - 1)
            if duty.countsAsOnDuty then
                local dutyGroup = target.dutyByGroup[duty.groupId]
                if dutyGroup then
                    dutyGroup.items[membershipId] = nil
                    dutyGroup.count = math.max(0, dutyGroup.count - 1)
                    if dutyGroup.count == 0 then
                        target.dutyByGroup[duty.groupId] = nil
                        target.dutyGroupCount = math.max(0, target.dutyGroupCount - 1)
                    end
                end
            end
        end
        target.membershipOwner[membershipId] = nil
        target.membershipCount = math.max(0, target.membershipCount - 1)
        return true
    end

    local function removeCharacter(target, characterId)
        local character = target.byCharacter[characterId]
        if not character then return 0 end
        local membershipIds = {}
        for membershipId in pairs(character.memberships) do
            membershipIds[#membershipIds + 1] = membershipId
        end
        for _, membershipId in ipairs(membershipIds) do
            removeMembership(target, membershipId)
        end
        target.byCharacter[characterId] = nil
        target.characterCount = math.max(0, target.characterCount - 1)
        return #membershipIds
    end

    local function insertPrevalidatedContext(target, context)
        local character = { characterId = context.characterId, memberships = {}, count = 0 }
        target.byCharacter[context.characterId] = character
        target.characterCount = target.characterCount + 1
        for _, membership in ipairs(context.memberships) do
            character.memberships[membership.membershipId] = membership
            character.count = character.count + 1
            target.membershipOwner[membership.membershipId] = membership
            target.membershipCount = target.membershipCount + 1
            local onlineGroup = target.onlineByGroup[membership.groupId]
            if not onlineGroup then
                onlineGroup = { count = 0, items = {} }
                target.onlineByGroup[membership.groupId] = onlineGroup
                target.onlineGroupCount = target.onlineGroupCount + 1
            end
            onlineGroup.items[membership.membershipId] = membership
            onlineGroup.count = onlineGroup.count + 1
            local duty = membership.dutySession
            if duty then
                target.dutyByMembership[membership.membershipId] = duty
                target.dutyBySession[duty.sessionId] = duty
                target.dutySessionCount = target.dutySessionCount + 1
                if duty.countsAsOnDuty then
                    local dutyGroup = target.dutyByGroup[duty.groupId]
                    if not dutyGroup then
                        dutyGroup = { count = 0, items = {} }
                        target.dutyByGroup[duty.groupId] = dutyGroup
                        target.dutyGroupCount = target.dutyGroupCount + 1
                    end
                    dutyGroup.items[membership.membershipId] = duty
                    dutyGroup.count = dutyGroup.count + 1
                end
            end
        end
    end

    local function insertContext(target, context)
        if target.byCharacter[context.characterId] then
            return nil, invalid('The runtime rebuild contains a duplicate character.', {
                characterId = context.characterId
            })
        end
        if target.characterCount >= maximumCharacters then
            return nil, capacity('The runtime index reached its character bound.', {
                maximum = maximumCharacters
            })
        end
        if target.membershipCount + #context.memberships > maximumMemberships then
            return nil, capacity('The runtime index reached its membership bound.', {
                maximum = maximumMemberships
            })
        end
        for _, membership in ipairs(context.memberships) do
            if target.membershipOwner[membership.membershipId] then
                return nil, invalid('A membership cannot belong to two online characters.', {
                    membershipId = membership.membershipId
                })
            end
            local duty = membership.dutySession
            if duty and target.dutyBySession[duty.sessionId] then
                return nil, invalid('An open duty session cannot belong to two memberships.', {
                    sessionId = duty.sessionId
                })
            end
        end
        insertPrevalidatedContext(target, context)
        return true, nil
    end

    local index = {}

    function index:replaceCharacter(characterId, context)
        local normalized, normalizeError = normalizeContext(characterId, context)
        if not normalized then return nil, normalizeError end
        local existing = state.byCharacter[characterId]
        local existingCount = existing and existing.count or 0
        if not existing and state.characterCount >= maximumCharacters then
            return nil, capacity('The runtime index reached its character bound.', {
                maximum = maximumCharacters
            })
        end
        if state.membershipCount - existingCount + #normalized.memberships
            > maximumMemberships then
            return nil, capacity('The runtime index reached its membership bound.', {
                maximum = maximumMemberships
            })
        end
        for _, membership in ipairs(normalized.memberships) do
            local owner = state.membershipOwner[membership.membershipId]
            if owner and owner.characterId ~= characterId then
                return nil, invalid('A membership is already indexed for another character.', {
                    membershipId = membership.membershipId
                })
            end
            local duty = membership.dutySession
            local dutyOwner = duty and state.dutyBySession[duty.sessionId] or nil
            if dutyOwner and dutyOwner.characterId ~= characterId then
                return nil, invalid('A duty session is already indexed for another character.', {
                    sessionId = duty.sessionId
                })
            end
        end
        -- Every condition that can reject insertion is checked above. The actual
        -- replacement is a non-yielding remove/insert pair, so readers never see
        -- a partial context and the old value is retained on all validation errors.
        removeCharacter(state, characterId)
        insertPrevalidatedContext(state, normalized)
        counters.loads = counters.loads + 1
        return true, nil
    end

    function index:removeCharacter(characterId)
        if not Foundation.isSubjectId(characterId) then return 0 end
        local existed = state.byCharacter[characterId] ~= nil
        local removed = removeCharacter(state, characterId)
        if existed then counters.unloads = counters.unloads + 1 end
        return removed
    end

    function index:invalidateGroup(groupId)
        if not Foundation.isPublicId(groupId) then return 0 end
        local bucket = state.onlineByGroup[groupId]
        if not bucket then return 0 end
        local membershipIds = {}
        for membershipId in pairs(bucket.items) do
            membershipIds[#membershipIds + 1] = membershipId
        end
        for _, membershipId in ipairs(membershipIds) do
            removeMembership(state, membershipId)
        end
        counters.invalidations = counters.invalidations + #membershipIds
        return #membershipIds
    end

    function index:clear()
        local removed = state.membershipCount
        state = emptyState()
        counters.invalidations = counters.invalidations + removed
        counters.clears = counters.clears + 1
        return removed
    end

    function index:rebuild(contexts)
        local contextCount, contextsAreArray = arraySize(contexts, maximumCharacters)
        if not contextsAreArray then
            return nil, invalid('Runtime rebuild contexts must be a contiguous bounded array.')
        end
        if contextCount > maximumCharacters then
            return nil, capacity('The runtime rebuild exceeds its character bound.', {
                maximum = maximumCharacters
            })
        end
        local replacement = emptyState()
        for indexValue, context in ipairs(contexts) do
            local characterId = type(context) == 'table' and context.characterId or nil
            local normalized, normalizeError = normalizeContext(characterId, context)
            if not normalized then
                if normalizeError and normalizeError.details == nil then
                    normalizeError.details = { index = indexValue }
                end
                return nil, normalizeError
            end
            local inserted, insertError = insertContext(replacement, normalized)
            if not inserted then return nil, insertError end
        end
        local removed = state.membershipCount
        state = replacement
        counters.rebuilds = counters.rebuilds + 1
        counters.invalidations = counters.invalidations + removed
        return true, nil
    end

    function index:refreshCharacter(characterId, loader)
        if not Foundation.isSubjectId(characterId) then
            return nil, invalid('The runtime refresh character identifier is invalid.')
        end
        if not state.byCharacter[characterId] then return true, nil end
        if not Foundation.isCallable(loader) then
            local removed = removeCharacter(state, characterId)
            counters.invalidations = counters.invalidations + math.max(1, removed)
            counters.refreshFailures = counters.refreshFailures + 1
            return nil, Foundation.domainError('RUNTIME_INDEX_REFRESH_FAILED',
                'The runtime context loader is unavailable.', true)
        end
        local called, context, loadError = pcall(loader, characterId)
        local thrownError = not called and type(context) == 'table' and context or nil
        if called and context == false and type(loadError) == 'table' then context = nil end
        if not called or context == nil then
            local removed = removeCharacter(state, characterId)
            counters.invalidations = counters.invalidations + math.max(1, removed)
            counters.refreshFailures = counters.refreshFailures + 1
            return nil, thrownError or type(loadError) == 'table' and loadError
                or Foundation.domainError('RUNTIME_INDEX_REFRESH_FAILED',
                    'The runtime character context could not be refreshed.', true)
        end
        local replaced, replaceError = self:replaceCharacter(characterId, context)
        if not replaced then
            local removed = removeCharacter(state, characterId)
            counters.invalidations = counters.invalidations + math.max(1, removed)
            counters.refreshFailures = counters.refreshFailures + 1
            return nil, replaceError
        end
        counters.refreshes = counters.refreshes + 1
        return true, nil
    end

    function index:characterIds()
        local identifiers = {}
        for characterId in pairs(state.byCharacter) do
            identifiers[#identifiers + 1] = characterId
        end
        table.sort(identifiers)
        return identifiers
    end

    function index:refreshAll(loader)
        if not Foundation.isCallable(loader) then
            local removed = self:clear()
            counters.refreshFailures = counters.refreshFailures + 1
            return nil, Foundation.domainError('RUNTIME_INDEX_REFRESH_FAILED',
                'The runtime context loader is unavailable.', true, {
                    invalidatedMemberships = removed
                })
        end
        local identifiers = self:characterIds()
        local firstError
        for _, characterId in ipairs(identifiers) do
            local refreshed, refreshError = self:refreshCharacter(characterId, loader)
            if not refreshed and firstError == nil then firstError = refreshError end
        end
        if firstError then return nil, firstError end
        return true, nil
    end

    function index:refreshGroup(groupId, loader)
        if not Foundation.isPublicId(groupId) then
            return nil, invalid('The runtime refresh group identifier is invalid.')
        end
        local bucket = state.onlineByGroup[groupId]
        if not bucket then return true, nil end
        local seen, identifiers = {}, {}
        for _, membership in pairs(bucket.items) do
            local characterId = membership.characterId
            if not seen[characterId] then
                seen[characterId] = true
                identifiers[#identifiers + 1] = characterId
            end
        end
        table.sort(identifiers)
        local firstError
        for _, characterId in ipairs(identifiers) do
            local refreshed, refreshError = self:refreshCharacter(characterId, loader)
            if not refreshed and firstError == nil then firstError = refreshError end
        end
        if firstError then return nil, firstError end
        return true, nil
    end

    function index:applyEffect(effect, loader)
        if type(effect) ~= 'table' or type(effect.action) ~= 'string' then return true, nil end
        if GROUP_INVALIDATION_ACTIONS[effect.action]
            and Foundation.isPublicId(effect.groupId) then
            self:invalidateGroup(effect.groupId)
            return true, nil
        end
        local requiresRefresh = effect.entityType == 'membership'
                and MEMBERSHIP_REFRESH_ACTIONS[effect.action] == true
            or effect.entityType == 'duty_session'
                and effect.action:sub(1, 5) == 'duty.'
        if not requiresRefresh then return true, nil end
        local characterId = effect.characterId
        if not Foundation.isSubjectId(characterId)
            and Foundation.isPublicId(effect.entityId) then
            local duty = state.dutyBySession[effect.entityId]
            characterId = duty and duty.characterId or nil
        end
        if not Foundation.isSubjectId(characterId) or not state.byCharacter[characterId] then
            return true, nil
        end
        return self:refreshCharacter(characterId, loader)
    end

    function index:isCharacterOnline(characterId)
        local found = Foundation.isSubjectId(characterId)
            and state.byCharacter[characterId] ~= nil
        counters[found and 'hits' or 'misses'] = counters[found and 'hits' or 'misses'] + 1
        return found
    end

    function index:getCharacterContext(characterId)
        local character = Foundation.isSubjectId(characterId)
            and state.byCharacter[characterId] or nil
        if not character then
            counters.misses = counters.misses + 1
            return nil
        end
        local memberships = {}
        for _, membership in pairs(character.memberships) do
            local copied = copyMembership(membership)
            if membership.dutySession then
                copied.dutySession = copyDuty(membership.dutySession)
            end
            memberships[#memberships + 1] = copied
        end
        counters.hits = counters.hits + 1
        return { characterId = characterId, memberships = memberships }
    end

    function index:getOnlineMembers(groupId)
        local bucket = Foundation.isPublicId(groupId) and state.onlineByGroup[groupId] or nil
        if not bucket then
            counters.misses = counters.misses + 1
            return {}
        end
        local members = {}
        for _, membership in pairs(bucket.items) do
            members[#members + 1] = copyMembership(membership)
        end
        counters.hits = counters.hits + 1
        return members
    end

    function index:countOnlineMembers(groupId)
        local bucket = Foundation.isPublicId(groupId) and state.onlineByGroup[groupId] or nil
        counters[bucket and 'hits' or 'misses'] = counters[bucket and 'hits' or 'misses'] + 1
        return bucket and bucket.count or 0
    end

    function index:getActiveDutyMembers(groupId)
        local bucket = Foundation.isPublicId(groupId) and state.dutyByGroup[groupId] or nil
        if not bucket then
            counters.misses = counters.misses + 1
            return {}
        end
        local sessions = {}
        for _, duty in pairs(bucket.items) do
            sessions[#sessions + 1] = copyDuty(duty)
        end
        counters.hits = counters.hits + 1
        return sessions
    end

    function index:countActiveDutyMembers(groupId)
        local bucket = Foundation.isPublicId(groupId) and state.dutyByGroup[groupId] or nil
        counters[bucket and 'hits' or 'misses'] = counters[bucket and 'hits' or 'misses'] + 1
        return bucket and bucket.count or 0
    end

    function index:getActiveDutySession(membershipId)
        local duty = Foundation.isPublicId(membershipId)
            and state.dutyByMembership[membershipId] or nil
        if not duty then
            counters.misses = counters.misses + 1
            return nil
        end
        counters.hits = counters.hits + 1
        return copyDuty(duty)
    end

    function index:snapshot()
        return {
            characters = state.characterCount,
            memberships = state.membershipCount,
            dutySessions = state.dutySessionCount,
            onlineGroups = state.onlineGroupCount,
            onDutyGroups = state.dutyGroupCount,
            maximumCharacters = maximumCharacters,
            maximumMemberships = maximumMemberships,
            maximumMembershipsPerCharacter = maximumMembershipsPerCharacter,
            hits = counters.hits,
            misses = counters.misses,
            loads = counters.loads,
            unloads = counters.unloads,
            rebuilds = counters.rebuilds,
            refreshes = counters.refreshes,
            refreshFailures = counters.refreshFailures,
            invalidations = counters.invalidations,
            clears = counters.clears
        }
    end

    return index
end

return createRuntimeIndex
end
