SynexSecurityExpectations = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Foundation = assert(SynexSecurityFoundation, 'security foundation must be loaded first')
local Expectations = SynexSecurityExpectations

local CONSTRAINT_KEYS = {
    categories = true, detectors = true, codes = true, correlationKeys = true,
    evidenceClasses = true, worldKeys = true, entityIds = true,
    maximumSeverity = true,
}

local REQUEST_KEYS = {
    expectationId = true, namespace = true, kind = true, subject = true,
    constraints = true, reason = true, ttlMs = true,
}

local REQUIRED_REQUEST_KEYS = {
    namespace = true, kind = true, subject = true, constraints = true,
    reason = true, ttlMs = true,
}

local PATCH_KEYS = { constraints = true, reason = true, ttlMs = true }

function Expectations.create(options)
    options = options or {}
    local now = assert(options.now, 'security expectation clock is required')
    assert(Validation.isCallable(now), 'security expectation clock is invalid')
    local serial = 0
    local nextId = Validation.isCallable(options.nextId) and options.nextId or function()
        serial = serial + 1
        return ('security:expectation:%012d'):format(serial)
    end
    local authorizeNamespace = Validation.isCallable(options.authorizeNamespace)
        and options.authorizeNamespace or Validation.namespaceOwned
    local isOwnerCurrent = Validation.isCallable(options.isOwnerCurrent)
        and options.isOwnerCurrent or nil
    local values, subjectIndex, ownerCounts, ownerEpochs, count = {}, {}, {}, {}, 0
    local registered, expired, revoked, staleRejected = 0, 0, 0, 0
    local api = {}

    local function copyExpectation(value)
        return Validation.copy(value, {
            maximumDepth = 8,
            maximumEntries = 192,
            maximumStringBytes = Limits.maximumReasonBytes,
            maximumBytes = Limits.maximumSignalBytes,
        })
    end

    local function remove(expectationId, reason)
        local value = values[expectationId]
        if value == nil then return nil end
        values[expectationId] = nil
        count = count - 1
        ownerCounts[value.ownerResource] = math.max(0,
            (ownerCounts[value.ownerResource] or 1) - 1)
        if ownerCounts[value.ownerResource] == 0 then ownerCounts[value.ownerResource] = nil end
        local subjectKey = Validation.subjectKey(value.subject)
        local bucket = subjectIndex[subjectKey]
        if bucket ~= nil then
            bucket[expectationId] = nil
            if next(bucket) == nil then subjectIndex[subjectKey] = nil end
        end
        if reason == 'expired' then expired = expired + 1 else revoked = revoked + 1 end
        return value
    end

    local function normalizeConstraints(value)
        if not Validation.exactObject(value, CONSTRAINT_KEYS) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation constraints contain unsupported fields.')
        end
        local result, selectorCount = {}, 0
        local arrayDefinitions = {
            categories = function(item) return Limits.categories[item] == true end,
            detectors = function(item) return Validation.semanticKey(item) end,
            codes = function(item) return Validation.errorCode(item) end,
            correlationKeys = function(item) return Validation.token(item, 3, 128) end,
            evidenceClasses = function(item) return Limits.evidenceClasses[item] == true end,
            worldKeys = function(item) return Validation.token(item, 3, 128) end,
            entityIds = function(item) return Validation.token(item, 3, 128) end,
        }
        for key, validator in pairs(arrayDefinitions) do
            if value[key] ~= nil then
                local items, itemError = Validation.stringArray(value[key],
                    Limits.maximumExpectationSelectors, validator)
                if not items then return nil, itemError end
                if #items == 0 then
                    return Validation.failure('SECURITY_EXPECTATION_INVALID',
                        'Security expectation selectors cannot be empty.')
                end
                if selectorCount + #items > Limits.maximumExpectationSelectors then
                    return Validation.failure('SECURITY_EXPECTATION_INVALID',
                        'The security expectation contains too many selectors.')
                end
                result[key], selectorCount = items, selectorCount + #items
            end
        end
        if value.maximumSeverity ~= nil then
            if not Limits.severities[value.maximumSeverity] then
                return Validation.failure('SECURITY_EXPECTATION_INVALID',
                    'The security expectation severity bound is invalid.')
            end
            result.maximumSeverity = value.maximumSeverity
        end
        if selectorCount == 0 then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'A security expectation requires at least one explicit signal selector.')
        end
        return result, nil
    end

    local function kindAllowsConstraints(kind, constraints)
        local categories = Limits.expectationKindCategories[kind]
        if type(categories) ~= 'table' then return false end
        for _, category in ipairs(constraints.categories or {}) do
            if categories[category] ~= true then return false end
        end
        return true
    end

    local function ownerReady(ownerResource, ownerEpoch)
        if not Validation.resourceName(ownerResource)
            or not Validation.isInteger(ownerEpoch, 1, Limits.maximumSafeInteger)
            or isOwnerCurrent ~= nil and not isOwnerCurrent(ownerResource, ownerEpoch) then
            staleRejected = staleRejected + 1
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security expectation owner is invalid or stale.')
        end
        local current = ownerEpochs[ownerResource]
        if current ~= nil and ownerEpoch < current then
            staleRejected = staleRejected + 1
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security expectation owner epoch is stale.')
        end
        if current == nil or ownerEpoch > current then
            if current ~= nil then
                local staleIds = {}
                for expectationId, expectation in pairs(values) do
                    if expectation.ownerResource == ownerResource then
                        staleIds[#staleIds + 1] = expectationId
                    end
                end
                for _, expectationId in ipairs(staleIds) do remove(expectationId, 'owner_restart') end
            end
            ownerEpochs[ownerResource] = ownerEpoch
        end
        return true, nil
    end

    function api.prune(at)
        local timestamp, ids = at or now(), {}
        for expectationId, expectation in pairs(values) do
            if expectation.expiresAt <= timestamp then ids[#ids + 1] = expectationId end
        end
        for _, expectationId in ipairs(ids) do remove(expectationId, 'expired') end
        return #ids
    end

    function api.register(request, context)
        context = context or {}
        api.prune(now())
        if not Validation.exactObject(request, REQUEST_KEYS, REQUIRED_REQUEST_KEYS) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation contains unsupported or missing fields.')
        end
        local ready, ownerError = ownerReady(context.ownerResource, context.ownerEpoch)
        if not ready then return nil, ownerError end
        if not Validation.namespace(request.namespace)
            or not authorizeNamespace(context.ownerResource, request.namespace)
            or not Limits.expectationKinds[request.kind]
            or not Validation.text(request.reason, 1, Limits.maximumReasonBytes)
            or not Validation.isInteger(request.ttlMs, Limits.minimumExpectationTtlMs,
                Limits.maximumExpectationTtlMs) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation classification or lifetime is invalid.')
        end
        local subject, subjectError = Validation.subject(request.subject)
        if not subject then return nil, subjectError end
        local constraints, constraintError = normalizeConstraints(request.constraints)
        if not constraints then return nil, constraintError end
        if not kindAllowsConstraints(request.kind, constraints) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation kind cannot select that signal category.')
        end
        if count >= (options.capacity or Limits.maximumExpectations)
            or (ownerCounts[context.ownerResource] or 0)
                >= (options.ownerCapacity or Limits.maximumOwnerExpectations) then
            return Validation.failure('SECURITY_EXPECTATION_LIMIT',
                'The bounded security expectation registry is full.', true)
        end
        local expectationId = request.expectationId or nextId('security.expectation')
        if not Validation.token(expectationId, 8, Limits.maximumIdentifierBytes) then
            return Validation.failure('SECURITY_ID_INVALID',
                'The security expectation identifier is invalid.')
        end
        if values[expectationId] ~= nil then
            return Validation.failure('SECURITY_EXPECTATION_CONFLICT',
                'The security expectation identifier already exists.')
        end
        local issuedAt = now()
        local expectation = {
            schemaVersion = Limits.schemaVersion,
            expectationId = expectationId,
            namespace = request.namespace,
            kind = request.kind,
            subject = subject,
            ownerResource = context.ownerResource,
            ownerEpoch = context.ownerEpoch,
            constraints = constraints,
            reason = request.reason,
            issuedAt = issuedAt,
            expiresAt = issuedAt + request.ttlMs,
            revision = 1,
        }
        values[expectationId] = expectation
        local subjectKey = Validation.subjectKey(subject)
        subjectIndex[subjectKey] = subjectIndex[subjectKey] or {}
        subjectIndex[subjectKey][expectationId] = true
        ownerCounts[context.ownerResource] = (ownerCounts[context.ownerResource] or 0) + 1
        count, registered = count + 1, registered + 1
        return copyExpectation(expectation), nil
    end

    function api.update(handle, patch, context)
        context = context or {}
        api.prune(now())
        if not Validation.exactObject(handle,
            { expectationId = true, revision = true },
            { expectationId = true, revision = true })
            or not Validation.token(handle.expectationId, 8, Limits.maximumIdentifierBytes)
            or not Validation.isInteger(handle.revision, 1, Limits.maximumSafeInteger)
            or not Validation.exactObject(patch, PATCH_KEYS) or next(patch) == nil then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation update is invalid.')
        end
        local ready, ownerError = ownerReady(context.ownerResource, context.ownerEpoch)
        if not ready then return nil, ownerError end
        local value = values[handle.expectationId]
        if value == nil then
            return Validation.failure('SECURITY_EXPECTATION_NOT_FOUND',
                'The security expectation was not found.')
        end
        if value.ownerResource ~= context.ownerResource
            or value.ownerEpoch ~= context.ownerEpoch then
            return Validation.failure('SECURITY_EXPECTATION_DENIED',
                'Only the current expectation owner can update it.')
        end
        if value.revision ~= handle.revision then
            return Validation.failure('SECURITY_EXPECTATION_STALE',
                'The security expectation revision is stale.', true)
        end
        local constraints = value.constraints
        if patch.constraints ~= nil then
            local constraintError
            constraints, constraintError = normalizeConstraints(patch.constraints)
            if not constraints then return nil, constraintError end
            if not kindAllowsConstraints(value.kind, constraints) then
                return Validation.failure('SECURITY_EXPECTATION_INVALID',
                    'The security expectation kind cannot select that signal category.')
            end
        end
        if patch.reason ~= nil
            and not Validation.text(patch.reason, 1, Limits.maximumReasonBytes)
            or patch.ttlMs ~= nil and not Validation.isInteger(patch.ttlMs,
                Limits.minimumExpectationTtlMs, Limits.maximumExpectationTtlMs) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation update values are invalid.')
        end
        local timestamp = now()
        value.constraints = constraints
        value.reason = patch.reason or value.reason
        if patch.ttlMs ~= nil then value.expiresAt = timestamp + patch.ttlMs end
        value.revision = value.revision + 1
        return copyExpectation(value), nil
    end

    function api.revoke(handle, context)
        context = context or {}
        if not Validation.exactObject(handle,
            { expectationId = true, revision = true },
            { expectationId = true, revision = true })
            or not Validation.token(handle.expectationId, 8,
                Limits.maximumIdentifierBytes)
            or not Validation.isInteger(handle.revision, 1,
                Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation handle is invalid.')
        end
        local ready, ownerError = ownerReady(context.ownerResource, context.ownerEpoch)
        if not ready then return nil, ownerError end
        local value = values[handle.expectationId]
        if value == nil then return true, nil end
        if value.ownerResource ~= context.ownerResource
            or value.ownerEpoch ~= context.ownerEpoch then
            return Validation.failure('SECURITY_EXPECTATION_DENIED',
                'Only the current expectation owner can revoke it.')
        end
        if value.revision ~= handle.revision then
            return Validation.failure('SECURITY_EXPECTATION_STALE',
                'The security expectation revision is stale.', true)
        end
        remove(handle.expectationId, 'revoked')
        return true, nil
    end

    function api.revokeOwner(ownerResource, ownerEpoch)
        if not Validation.resourceName(ownerResource)
            or not Validation.isInteger(ownerEpoch, 1, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_OWNER_STALE',
                'The security expectation owner is invalid.')
        end
        local ids = {}
        for expectationId, expectation in pairs(values) do
            if expectation.ownerResource == ownerResource
                and expectation.ownerEpoch == ownerEpoch then ids[#ids + 1] = expectationId end
        end
        for _, expectationId in ipairs(ids) do remove(expectationId, 'owner_stop') end
        return #ids, nil
    end

    function api.activateOwner(ownerResource, ownerEpoch)
        local ready, ownerError = ownerReady(ownerResource, ownerEpoch)
        if not ready then return nil, ownerError end
        return true, nil
    end

    function api.match(signal)
        api.prune(now())
        local subject = Foundation.subjectFromSignal(signal)
        local result = {}
        local function includes(valuesToCheck, candidate)
            if valuesToCheck == nil then return true end
            for _, item in ipairs(valuesToCheck) do
                if item == candidate then return true end
            end
            return false
        end
        local candidateIds = {}
        if subject.sessionId ~= nil then
            local key = 'session:' .. subject.sessionId .. ':'
                .. tostring(subject.sourceGeneration)
            for expectationId in pairs(subjectIndex[key] or {}) do
                candidateIds[expectationId] = true
            end
        end
        if subject.userId ~= nil then
            for expectationId in pairs(subjectIndex['user:' .. subject.userId] or {}) do
                candidateIds[expectationId] = true
            end
        end
        if subject.characterId ~= nil then
            for expectationId in pairs(subjectIndex['character:' .. subject.characterId] or {}) do
                candidateIds[expectationId] = true
            end
        end
        if subject.resourceName ~= nil then
            for expectationId in pairs(subjectIndex['resource:' .. subject.resourceName] or {}) do
                candidateIds[expectationId] = true
            end
        end
        for expectationId in pairs(candidateIds) do
            local expectation = values[expectationId]
            local kindCategories = Limits.expectationKindCategories[expectation.kind]
            local expected = type(kindCategories) == 'table'
                and kindCategories[signal.category] == true
                and (expectation.subject.sessionId == nil
                    or expectation.subject.sessionId == subject.sessionId
                        and expectation.subject.sourceGeneration == subject.sourceGeneration
                        and (expectation.subject.source == nil
                            or expectation.subject.source == subject.source))
                and (expectation.subject.userId == nil
                    or expectation.subject.userId == subject.userId)
                and (expectation.subject.characterId == nil
                    or expectation.subject.characterId == subject.characterId)
                and (expectation.subject.resourceName == nil
                    or expectation.subject.resourceName == subject.resourceName)
                and includes(expectation.constraints.categories, signal.category)
                and includes(expectation.constraints.detectors, signal.detector)
                and includes(expectation.constraints.codes, signal.code)
                and includes(expectation.constraints.correlationKeys, signal.correlationKey)
                and includes(expectation.constraints.evidenceClasses, signal.evidenceClass)
            if expected and expectation.constraints.maximumSeverity ~= nil then
                expected = Limits.severityRanks[signal.severity]
                    <= Limits.severityRanks[expectation.constraints.maximumSeverity]
            end
            if expected and expectation.constraints.worldKeys ~= nil then
                local worldKey = type(signal.worldRef) == 'table'
                    and (signal.worldRef.key or signal.worldRef.worldId) or nil
                expected = includes(expectation.constraints.worldKeys, worldKey)
            end
            if expected and expectation.constraints.entityIds ~= nil then
                local entityId = type(signal.entityRef) == 'table'
                    and (signal.entityRef.entityId or signal.entityRef.id) or nil
                expected = includes(expectation.constraints.entityIds, entityId)
            end
            if expected then result[#result + 1] = copyExpectation(expectation) end
        end
        table.sort(result, function(left, right)
            return left.expiresAt < right.expiresAt
        end)
        return result, nil
    end

    function api.get(expectationId)
        api.prune(now())
        local value = values[expectationId]
        if value == nil then
            return Validation.failure('SECURITY_EXPECTATION_NOT_FOUND',
                'The security expectation was not found.')
        end
        return copyExpectation(value), nil
    end

    function api.list(request)
        request = request or {}
        api.prune(now())
        local limit = request.limit or 64
        local offset = request.offset or 0
        if not Validation.isInteger(limit, 1, 256)
            or not Validation.isInteger(offset, 0,
                options.capacity or Limits.maximumExpectations)
            or request.ownerResource ~= nil
                and not Validation.resourceName(request.ownerResource)
            or request.subjectKey ~= nil
                and not Validation.token(request.subjectKey, 3, 256) then
            return Validation.failure('SECURITY_EXPECTATION_INVALID',
                'The security expectation page request is invalid.')
        end
        local ordered = {}
        local candidateIds = request.subjectKey ~= nil
            and subjectIndex[request.subjectKey] or values
        for expectationId in pairs(candidateIds or {}) do
            local value = values[expectationId]
            if value ~= nil and (request.ownerResource == nil
                or value.ownerResource == request.ownerResource) then
                ordered[#ordered + 1] = value
            end
        end
        table.sort(ordered, function(left, right)
            if left.expiresAt == right.expiresAt then
                return left.expectationId < right.expectationId
            end
            return left.expiresAt < right.expiresAt
        end)
        local result = {}
        for index = offset + 1, math.min(offset + limit, #ordered) do
            result[#result + 1] = copyExpectation(ordered[index])
        end
        return result, nil, { total = #ordered, offset = offset }
    end

    function api.snapshot()
        return {
            active = count,
            capacity = options.capacity or Limits.maximumExpectations,
            owners = #Foundation.sortedKeys(ownerCounts),
            registered = registered,
            expired = expired,
            revoked = revoked,
            staleRejected = staleRejected,
        }
    end

    function api.audit(at)
        local timestamp = at or now()
        if not Validation.isInteger(timestamp, 0, Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_CLOCK_INVALID',
                'The expectation audit clock is invalid.', true)
        end
        local expiredActive, staleOwners = 0, 0
        for _, expectation in pairs(values) do
            if expectation.expiresAt <= timestamp then
                expiredActive = expiredActive + 1
            elseif isOwnerCurrent ~= nil
                and isOwnerCurrent(expectation.ownerResource,
                    expectation.ownerEpoch) ~= true then
                staleOwners = staleOwners + 1
            end
        end
        return {
            active = count,
            expiredActive = expiredActive,
            staleOwners = staleOwners,
            ownerCheckAvailable = isOwnerCurrent ~= nil,
        }, nil
    end

    return api
end
