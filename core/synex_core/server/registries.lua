local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.registries = function(deps)
    local foundation = assert(deps.foundation, 'registries require foundation')

    local owners = {}
    local resources = {}
    local resourceEpochs = {}
    local sessions = {}
    local pending = {}
    local bySource = {}
    local sourceEpoch = {}
    local byUser = {}
    local byCharacter = {}
    local byIdentifier = {}
    local maximumSourceGeneration = 9007199254740991
    local sourceGenerationFloor = 0
    local sourceGenerationSeeded = false
    local maximumPendingDiagnosticAgeMs = 600000

    local ownerIndex = {}
    function ownerIndex:epoch(resource)
        return resourceEpochs[resource] or 0
    end
    function ownerIndex:activate(resource)
        resourceEpochs[resource] = (resourceEpochs[resource] or 0) + 1
        owners[resource] = {
            epoch = resourceEpochs[resource],
            artifacts = {},
            operations = {},
            quiescing = false,
            quiesceReason = nil
        }
        return resourceEpochs[resource]
    end
    function ownerIndex:isEpoch(resource, epoch)
        local owner = owners[resource]
        return owner ~= nil and owner.epoch == epoch
    end
    function ownerIndex:isCurrent(resource, epoch)
        local owner = owners[resource]
        return owner ~= nil and owner.epoch == epoch and owner.quiescing ~= true
    end
    function ownerIndex:isQuiescing(resource, epoch)
        local owner = owners[resource]
        return owner ~= nil and owner.epoch == epoch and owner.quiescing == true
    end
    function ownerIndex:beginQuiesce(resource, epoch, reason)
        local owner = owners[resource]
        if not owner or owner.epoch ~= epoch then
            return nil, foundation.error('STALE_RESOURCE', 'The resource owner epoch is no longer active.')
        end
        owner.quiescing = true
        owner.quiesceReason = tostring(reason or 'resource restart')
        return { epoch = owner.epoch, pending = self:pendingCount(resource, epoch) }, nil
    end
    function ownerIndex:beginOperation(resource, epoch, abort)
        if abort ~= nil and type(abort) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Operation abort callback must be a function.')
        end
        if not self:isCurrent(resource, epoch) then
            return nil, foundation.error('OWNER_QUIESCING', 'The resource owner is unavailable or quiescing.', { retryable = true })
        end
        local token = foundation.nextId('operation')
        owners[resource].operations[token] = { abort = abort }
        return token, nil
    end
    function ownerIndex:finishOperation(resource, epoch, token)
        local owner = owners[resource]
        if not owner or owner.epoch ~= epoch or not owner.operations[token] then return false end
        owner.operations[token] = nil
        return true
    end
    function ownerIndex:pendingCount(resource, epoch)
        local owner = owners[resource]
        if not owner or (epoch ~= nil and owner.epoch ~= epoch) then return 0 end
        local count = 0
        for _ in pairs(owner.operations) do count = count + 1 end
        return count
    end
    function ownerIndex:abortPending(resource, epoch, reason)
        local owner = owners[resource]
        if not owner or owner.epoch ~= epoch then
            return { aborted = 0, errors = {}, stale = true }
        end
        local operations = {}
        for token, operation in pairs(owner.operations) do
            operations[#operations + 1] = { token = token, operation = operation }
        end
        table.sort(operations, function(a, b) return tostring(a.token) < tostring(b.token) end)
        local report = { aborted = 0, errors = {} }
        for _, item in ipairs(operations) do
            if owner.operations[item.token] == item.operation then
                owner.operations[item.token] = nil
                if type(item.operation.abort) == 'function' then
                    local ok, err = foundation.safeCall(item.operation.abort, tostring(reason or 'owner quiesced'))
                    if not ok then
                        report.errors[#report.errors + 1] = { token = item.token, error = tostring(err) }
                    end
                end
                report.aborted = report.aborted + 1
            end
        end
        return report
    end
    function ownerIndex:track(resource, epoch, kind, token, cleanup)
        if not self:isCurrent(resource, epoch) then
            return nil, foundation.error('STALE_RESOURCE', 'The resource owner epoch is no longer active.')
        end
        local artifacts = owners[resource].artifacts
        artifacts[kind] = artifacts[kind] or {}
        artifacts[kind][token] = cleanup
        return token, nil
    end
    function ownerIndex:release(resource, kind, token)
        local owner = owners[resource]
        if not owner or not owner.artifacts[kind] then return false end
        owner.artifacts[kind][token] = nil
        return true
    end
    function ownerIndex:list()
        local result = {}
        for resource, owner in pairs(owners) do
            result[#result + 1] = {
                resource = resource,
                epoch = owner.epoch,
                quiescing = owner.quiescing == true,
                pending = self:pendingCount(resource, owner.epoch)
            }
        end
        table.sort(result, function(a, b) return a.resource < b.resource end)
        return result
    end
    function ownerIndex:purge(resource, expectedEpoch, reason)
        local owner = owners[resource]
        if not owner then return { cleaned = 0, aborted = 0, errors = {}, stale = expectedEpoch ~= nil } end
        if expectedEpoch ~= nil and owner.epoch ~= expectedEpoch then
            return { cleaned = 0, aborted = 0, errors = {}, stale = true, activeEpoch = owner.epoch }
        end
        owner.quiescing = true
        owner.quiesceReason = tostring(reason or owner.quiesceReason or 'resource purge')
        resourceEpochs[resource] = math.max(resourceEpochs[resource] or 0, owner.epoch) + 1
        local abortReport = self:abortPending(resource, owner.epoch, owner.quiesceReason)
        local cleanups = {}
        for kind, artifacts in pairs(owner.artifacts) do
            for token, cleanup in pairs(artifacts) do
                cleanups[#cleanups + 1] = { kind = kind, token = token, cleanup = cleanup }
            end
        end
        table.sort(cleanups, function(a, b)
            if a.kind == b.kind then return tostring(a.token) < tostring(b.token) end
            return a.kind < b.kind
        end)
        local report = { cleaned = 0, aborted = abortReport.aborted, errors = {} }
        for _, abortError in ipairs(abortReport.errors) do
            report.errors[#report.errors + 1] = {
                kind = 'operation', token = abortError.token, error = abortError.error
            }
        end
        for _, item in ipairs(cleanups) do
            if type(item.cleanup) == 'function' then
                local ok, err = foundation.safeCall(item.cleanup)
                if not ok then report.errors[#report.errors + 1] = { kind = item.kind, token = item.token, error = tostring(err) } end
            end
            report.cleaned = report.cleaned + 1
        end
        if owners[resource] == owner then owners[resource] = nil end
        return report
    end

    local resourceRegistry = {}
    function resourceRegistry:upsert(name, manifest, state)
        local existing = resources[name]
        local epoch = existing and existing.epoch or ownerIndex:epoch(name)
        resources[name] = {
            name = name,
            manifest = foundation.copy(manifest),
            state = state or 'DISCOVERED',
            health = { status = 'UNKNOWN', reasons = {} },
            epoch = epoch
        }
        return foundation.copy(resources[name])
    end
    function resourceRegistry:setState(name, state, health)
        local resource = resources[name]
        if not resource then return nil, foundation.error('RESOURCE_NOT_FOUND', 'The resource is not registered.') end
        resource.state = state
        resource.epoch = ownerIndex:epoch(name)
        if health then resource.health = foundation.copy(health) end
        return foundation.copy(resource), nil
    end
    function resourceRegistry:get(name) return resources[name] and foundation.copy(resources[name]) or nil end
    function resourceRegistry:list()
        local list = {}
        for _, resource in pairs(resources) do list[#list + 1] = foundation.copy(resource) end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end
    function resourceRegistry:summary()
        local summary = { total = 0, healthy = 0, degraded = 0, unhealthy = 0, unknown = 0, states = {} }
        for _, resource in pairs(resources) do
            summary.total = summary.total + 1
            summary.states[resource.state] = (summary.states[resource.state] or 0) + 1
            local status = resource.health and resource.health.status or 'UNKNOWN'
            local key = type(status) == 'string' and status:lower() or 'unknown'
            if summary[key] == nil then key = 'unknown' end
            summary[key] = summary[key] + 1
        end
        return summary
    end

    local playerRegistry = {}
    function playerRegistry:seedSourceGeneration(generation)
        if sourceGenerationSeeded or next(sessions) ~= nil or next(pending) ~= nil then
            return nil, foundation.error('SOURCE_GENERATION_ALREADY_ACTIVE',
                'Source generation can only be seeded once before player admission.')
        end
        generation = tonumber(generation)
        if not generation or math.type(generation) ~= 'integer'
            or generation < 0 or generation > 9007199254740990 then
            return nil, foundation.error('INVALID_SOURCE_GENERATION',
                'Source generation seed must be a safe non-negative integer.')
        end
        sourceGenerationFloor = generation
        sourceGenerationSeeded = true
        return true, nil
    end
    function playerRegistry:createPending(tempSource, connection)
        if pending[tempSource] then return nil, foundation.error('DUPLICATE_PENDING', 'A pending connection already uses this source.') end
        pending[tempSource] = foundation.copy(connection)
        pending[tempSource].createdAtMs = foundation.monotonicMs()
        return foundation.copy(pending[tempSource]), nil
    end
    function playerRegistry:getPending(tempSource) return pending[tempSource] and foundation.copy(pending[tempSource]) or nil end
    function playerRegistry:updatePending(tempSource, mutator)
        local connection = pending[tempSource]
        if not connection then return nil, foundation.error('PENDING_CONNECTION_NOT_FOUND', 'The pending connection does not exist.') end
        if type(mutator) ~= 'function' then return nil, foundation.error('INVALID_ARGUMENT', 'A pending connection mutator is required.') end
        local candidate = foundation.copy(connection)
        local ok, mutationError = foundation.safeCall(mutator, candidate)
        if not ok then
            return nil, foundation.error('PENDING_CONNECTION_UPDATE_FAILED', 'The pending connection update failed.', {
                details = tostring(mutationError)
            })
        end
        if candidate.id ~= connection.id or candidate.tempSource ~= connection.tempSource then
            return nil, foundation.error('PENDING_CONNECTION_IDENTITY_CHANGED', 'Pending connection identity is immutable.')
        end
        pending[tempSource] = candidate
        return foundation.copy(candidate), nil
    end
    function playerRegistry:listPending()
        local result = {}
        for source, connection in pairs(pending) do result[#result + 1] = { source = source, connection = foundation.copy(connection) } end
        table.sort(result, function(a, b) return tostring(a.source) < tostring(b.source) end)
        return result
    end
    function playerRegistry:removePending(tempSource)
        local value = pending[tempSource]
        pending[tempSource] = nil
        return value and foundation.copy(value) or nil
    end
    function playerRegistry:bindJoined(tempSource, finalSource, session)
        local connection = pending[tempSource]
        if not connection or connection.sessionId ~= session.id then
            return nil, foundation.error('PENDING_CONNECTION_NOT_FOUND', 'No accepted connection matches this join.')
        end
        if bySource[finalSource] then
            return nil, foundation.error('SOURCE_ALREADY_BOUND', 'The final source is already bound.')
        end
        local previousGeneration = math.max(sourceEpoch[finalSource] or 0, sourceGenerationFloor)
        if previousGeneration >= maximumSourceGeneration then
            return nil, foundation.error('SOURCE_GENERATION_EXHAUSTED',
                'The persisted source generation cannot be advanced safely.')
        end
        local generation = previousGeneration + 1
        local stored = foundation.copy(session)
        stored.source = finalSource
        stored.sourceGeneration = generation
        sessions[stored.id] = stored
        bySource[finalSource] = { sessionId = stored.id, generation = generation }
        sourceEpoch[finalSource] = generation
        if stored.userId then
            local index = byUser[stored.userId] or { primary = nil, sessions = {} }
            index.sessions[stored.id] = true
            index.primary = index.primary or stored.id
            byUser[stored.userId] = index
        end
        pending[tempSource] = nil
        return foundation.copy(stored), nil
    end
    function playerRegistry:getSession(id) return sessions[id] and foundation.copy(sessions[id]) or nil end
    function playerRegistry:getBySource(source)
        local index = bySource[source]
        return index and sessions[index.sessionId] and foundation.copy(sessions[index.sessionId]) or nil
    end
    function playerRegistry:isCurrent(sessionId, source, generation)
        local index = bySource[source]
        return index ~= nil and index.sessionId == sessionId and index.generation == generation
    end
    function playerRegistry:detachSource(sessionId, source, generation)
        local session = sessions[sessionId]
        local index = bySource[source]
        if not session or session.source ~= source or session.sourceGeneration ~= generation
            or not index or index.sessionId ~= sessionId or index.generation ~= generation then
            return nil, foundation.error('SOURCE_NOT_CURRENT', 'The player source binding is no longer current.')
        end
        local detached = foundation.copy(session)
        bySource[source] = nil
        local previousGeneration = math.max(sourceEpoch[source] or 0, generation)
        sourceEpoch[source] = previousGeneration >= maximumSourceGeneration
            and maximumSourceGeneration or previousGeneration + 1
        session.source = nil
        session.sourceGeneration = sourceEpoch[source]
        return detached, nil
    end
    function playerRegistry:updateSession(sessionId, mutator)
        local session = sessions[sessionId]
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        local candidate = foundation.copy(session)
        local ok, err = foundation.safeCall(mutator, candidate)
        if not ok then return nil, foundation.error('SESSION_UPDATE_FAILED', 'The session update failed.', { details = tostring(err) }) end
        sessions[sessionId] = candidate
        return foundation.copy(candidate), nil
    end
    function playerRegistry:bindCharacter(sessionId, characterId)
        local session = sessions[sessionId]
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if byCharacter[characterId] and byCharacter[characterId] ~= sessionId then
            return nil, foundation.error('CHARACTER_ALREADY_ACTIVE', 'The character is active in another session.')
        end
        if session.characterId then byCharacter[session.characterId] = nil end
        session.characterId = characterId
        byCharacter[characterId] = sessionId
        return foundation.copy(session), nil
    end
    function playerRegistry:unbindCharacter(sessionId)
        local session = sessions[sessionId]
        if not session then return nil, foundation.error('SESSION_NOT_FOUND', 'The session does not exist.') end
        if session.characterId and byCharacter[session.characterId] == sessionId then byCharacter[session.characterId] = nil end
        session.characterId = nil
        return foundation.copy(session), nil
    end
    function playerRegistry:bindIdentifier(identifier, userId)
        local existing = byIdentifier[identifier]
        if existing and existing ~= userId then
            return nil, foundation.error('IDENTIFIER_CONFLICT', 'The identifier belongs to another user.')
        end
        byIdentifier[identifier] = userId
        return true, nil
    end
    function playerRegistry:userByIdentifier(identifier) return byIdentifier[identifier] end
    function playerRegistry:sessionsByUser(userId)
        local index = byUser[userId]
        local result = {}
        if index then
            for sessionId in pairs(index.sessions) do
                if sessions[sessionId] then result[#result + 1] = foundation.copy(sessions[sessionId]) end
            end
        end
        table.sort(result, function(a, b) return a.id < b.id end)
        return result
    end
    function playerRegistry:removeSession(sessionId)
        local session = sessions[sessionId]
        if not session then return nil end
        if session.source ~= nil then
            local index = bySource[session.source]
            if index and index.sessionId == sessionId then
                bySource[session.source] = nil
                local previousGeneration = math.max(sourceEpoch[session.source] or 0, index.generation)
                sourceEpoch[session.source] = previousGeneration >= maximumSourceGeneration
                    and maximumSourceGeneration or previousGeneration + 1
            end
        end
        if session.userId and byUser[session.userId] then
            local userIndex = byUser[session.userId]
            userIndex.sessions[sessionId] = nil
            if userIndex.primary == sessionId then userIndex.primary = next(userIndex.sessions) end
            if not next(userIndex.sessions) then byUser[session.userId] = nil end
        end
        if session.characterId and byCharacter[session.characterId] == sessionId then byCharacter[session.characterId] = nil end
        sessions[sessionId] = nil
        return foundation.copy(session)
    end
    function playerRegistry:snapshot()
        local output = { sessions = {}, pending = 0 }
        for _, session in pairs(sessions) do output.sessions[#output.sessions + 1] = foundation.copy(session) end
        for _ in pairs(pending) do output.pending = output.pending + 1 end
        table.sort(output.sessions, function(a, b) return a.id < b.id end)
        return output
    end
    function playerRegistry:summary()
        local summary = {
            activeSessions = 0,
            pendingConnections = 0,
            expiredPendingConnections = 0,
            oldestPendingAgeMs = 0,
            pendingAgeCapped = false,
            states = {}
        }
        for _, session in pairs(sessions) do
            summary.activeSessions = summary.activeSessions + 1
            summary.states[session.state] = (summary.states[session.state] or 0) + 1
        end
        local now = foundation.monotonicMs()
        for _, connection in pairs(pending) do
            summary.pendingConnections = summary.pendingConnections + 1
            local createdAt = tonumber(connection.createdAtMs) or now
            local age = math.max(0, math.floor(now - createdAt))
            if age > maximumPendingDiagnosticAgeMs then
                age = maximumPendingDiagnosticAgeMs
                summary.pendingAgeCapped = true
            end
            summary.oldestPendingAgeMs = math.max(summary.oldestPendingAgeMs, age)
            if type(connection.expiresAt) == 'number' and connection.expiresAt <= now then
                summary.expiredPendingConnections = summary.expiredPendingConnections + 1
            end
        end
        return summary
    end

    return {
        owners = ownerIndex,
        resources = resourceRegistry,
        players = playerRegistry
    }
end
