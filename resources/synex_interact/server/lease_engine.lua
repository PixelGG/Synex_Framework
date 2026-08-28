SynexInteractLeaseEngine = {}

local Engine = SynexInteractLeaseEngine
local V = SynexInteractValidation
local L = SynexInteractLimits

function Engine.create(options)
    local now = assert(options.now, 'lease engine requires monotonic clock')
    local nextId = assert(options.nextId, 'lease engine requires id generator')
    local leases, bySource, byTarget = {}, {}, {}
    local api = {}

    local function expire(lease, reason)
        if not lease or lease.state ~= 'ACTIVE' then return end
        lease.state = reason or 'EXPIRED'
        leases[lease.id] = nil
        if bySource[lease.source] == lease.id then bySource[lease.source] = nil end
        if byTarget[lease.slotKey] == lease.id then byTarget[lease.slotKey] = nil end
    end

    local function getActive(id)
        local lease = leases[id]
        if not lease then return nil end
        if lease.expiresAt <= now() then expire(lease, 'EXPIRED'); return nil end
        return lease
    end

    function api.acquire(request)
        if type(request) ~= 'table' or not V.isInteger(request.source, 1, 65535)
            or type(request.sessionId) ~= 'string' or #request.sessionId < 1
            or not V.isInteger(request.sourceGeneration, 1, 9007199254740991) then
            return V.failure('INTERACT_INVALID_ARGUMENT', 'Interaction lease request is invalid.')
        end
        local objectKey, objectError = V.key(request.objectKey, 'objectKey')
        if not objectKey then return nil, objectError end
        local actionKey, actionError = V.key(request.actionKey, 'actionKey')
        if not actionKey then return nil, actionError end
        local slotKey = objectKey .. '\0' .. (request.slot or 'default')
        local current = byTarget[slotKey] and getActive(byTarget[slotKey]) or nil
        if current and current.source ~= request.source then
            return V.failure('INTERACT_SLOT_BUSY', 'Interaction slot is already reserved.', true)
        end
        local sourceLease = bySource[request.source] and getActive(bySource[request.source]) or nil
        if sourceLease then expire(sourceLease, 'SUPERSEDED') end
        local ttl = V.clamp(request.ttlSeconds or L.defaultLeaseSeconds, 1, L.maximumLeaseSeconds)
        local id, idError = nextId('interact_lease')
        if not id then return nil, idError end
        local lease = {
            id = tostring(id), source = request.source, sessionId = request.sessionId,
            sourceGeneration = request.sourceGeneration, objectKey = objectKey,
            actionKey = actionKey, slotKey = slotKey, ownerResource = request.ownerResource,
            acquiredAt = now(), expiresAt = now() + ttl * 1000, renewals = 0,
            state = 'ACTIVE', contextFingerprint = request.contextFingerprint,
        }
        leases[lease.id], bySource[lease.source], byTarget[slotKey] = lease, lease.id, lease.id
        return V.copy(lease)
    end

    function api.verify(id, expected)
        local lease = getActive(id)
        if not lease then return V.failure('INTERACT_LEASE_EXPIRED', 'Interaction lease is unavailable.', true) end
        if expected then
            if lease.source ~= expected.source or lease.sessionId ~= expected.sessionId
                or lease.sourceGeneration ~= expected.sourceGeneration
                or expected.objectKey and lease.objectKey ~= expected.objectKey
                or expected.actionKey and lease.actionKey ~= expected.actionKey then
                return V.failure('INTERACT_LEASE_STALE', 'Interaction lease no longer matches the active session.')
            end
        end
        return V.copy(lease)
    end

    function api.renew(id, expected, ttlSeconds)
        local lease, leaseError = api.verify(id, expected)
        if not lease then return nil, leaseError end
        local mutable = leases[id]
        if mutable.renewals >= L.maximumLeaseRenewals then
            return V.failure('INTERACT_LEASE_RENEWAL_LIMIT', 'Interaction lease renewal limit was reached.')
        end
        mutable.renewals = mutable.renewals + 1
        mutable.expiresAt = now() + V.clamp(ttlSeconds or L.defaultLeaseSeconds, 1, L.maximumLeaseSeconds) * 1000
        return V.copy(mutable)
    end

    function api.release(id, reason)
        local lease = leases[id]
        if not lease then return true end
        expire(lease, reason or 'RELEASED')
        return true
    end

    function api.releaseSource(source)
        local id = bySource[source]
        if id then expire(leases[id], 'SOURCE_LEFT') end
    end

    function api.releaseOwner(owner)
        local ids = {}
        for id, lease in pairs(leases) do if lease.ownerResource == owner then ids[#ids + 1] = id end end
        for _, id in ipairs(ids) do expire(leases[id], 'OWNER_STOPPED') end
        return #ids
    end

    function api.stats()
        local active = 0
        for id in pairs(leases) do if getActive(id) then active = active + 1 end end
        return { active = active }
    end

    return api
end
