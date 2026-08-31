SynexInteractSlots = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractSlots.create(options)
    options = options or {}
    local now = assert(options.now, 'slot runtime requires a monotonic clock')
    local slots, reservations, reservationCount = {}, {}, 0
    local objectReservations = {}
    local runtime = {}

    local function slotId(objectKey, slotKey)
        return objectKey .. '#' .. slotKey
    end

    local function copySlot(slot)
        local occupied, reserved = 0, 0
        for _, units in pairs(slot.occupants) do occupied = occupied + units end
        for _, units in pairs(slot.reservations) do reserved = reserved + units end
        return {
            id = slot.id, objectKey = slot.objectKey, key = slot.key,
            ownerResource = slot.ownerResource, ownerEpoch = slot.ownerEpoch,
            bundleRevision = slot.bundleRevision, state = slot.disabled and 'DISABLED'
                or occupied > 0 and 'OCCUPIED' or reserved > 0 and 'RESERVED' or 'FREE',
            capacity = slot.capacity, occupied = occupied, reserved = reserved,
        }
    end

    local function releaseRecord(record)
        if not record or record.released then return false end
        record.released = true
        for _, id in ipairs(record.slotIds) do
            local slot = slots[id]
            if slot then
                slot.reservations[record.id] = nil
                slot.occupants[record.id] = nil
            end
        end
        for _, objectKey in ipairs(record.objectKeys or {}) do
            local index = objectReservations[objectKey]
            if index then
                index[record.id] = nil
                if next(index) == nil then objectReservations[objectKey] = nil end
            end
        end
        reservations[record.id] = nil
        reservationCount = math.max(0, reservationCount - 1)
        return true
    end

    function runtime.reconcile(bundleRecords)
        local nextSlots = {}
        for _, record in ipairs(bundleRecords or {}) do
            local bundle, object = record.bundle, record.object
            local objectAvailability = object.availabilityPolicy or { enabled = true }
            local concurrencyMode = type(object.concurrencyPolicy) == 'table'
                and object.concurrencyPolicy.mode or 'slot'
            for _, key in ipairs(object.slotOrder or {}) do
                local definition = object.slots[key]
                local slotAvailability = definition.availabilityPolicy
                    or { enabled = true }
                local id, previous = slotId(object.key, key), slots[slotId(object.key, key)]
                local compatible = previous and previous.ownerResource == bundle.ownerResource
                    and previous.ownerEpoch == bundle.ownerEpoch
                    and previous.bundleRevision == bundle.revision
                    and previous.capacity == definition.capacity
                    and previous.concurrencyMode == concurrencyMode
                nextSlots[id] = compatible and previous or {
                    id = id, objectKey = object.key, key = key,
                    ownerResource = bundle.ownerResource, ownerEpoch = bundle.ownerEpoch,
                    bundleRevision = bundle.revision, capacity = definition.capacity,
                    disabled = definition.initialState == 'DISABLED'
                        or objectAvailability.enabled == false
                        or slotAvailability.enabled == false,
                    concurrencyMode = concurrencyMode,
                    reservations = {}, occupants = {},
                }
            end
        end
        for id, previous in pairs(slots) do
            if not nextSlots[id] then
                local ids = {}
                for reservationId in pairs(previous.reservations) do ids[#ids + 1] = reservationId end
                for reservationId in pairs(previous.occupants) do ids[#ids + 1] = reservationId end
                for _, reservationId in ipairs(ids) do releaseRecord(reservations[reservationId]) end
            elseif nextSlots[id] ~= previous then
                local ids = {}
                for reservationId in pairs(previous.reservations) do ids[#ids + 1] = reservationId end
                for reservationId in pairs(previous.occupants) do ids[#ids + 1] = reservationId end
                for _, reservationId in ipairs(ids) do releaseRecord(reservations[reservationId]) end
            end
        end
        slots = nextSlots
    end

    function runtime.reserve(request)
        if not Validation.exactObject(request, {
            'reservationId', 'sessionId', 'actorKey', 'slotClaims', 'expiresAt',
            'ownerResource', 'ownerEpoch', 'bundleRevision',
        }) or not Validation.token(request.reservationId)
            or not Validation.token(request.sessionId)
            or not Validation.actorKey(request.actorKey)
            or not Validation.isInteger(request.expiresAt, 1)
            or not Validation.resourceName(request.ownerResource)
            or not Validation.isInteger(request.ownerEpoch, 1)
            or not Validation.isInteger(request.bundleRevision, 1) then
            return Validation.failure('INTERACT_RESERVATION_INVALID',
                'The interaction reservation is invalid.')
        end
        if reservations[request.reservationId] or reservationCount >= Limits.maximumReservations then
            return Validation.failure('INTERACT_SLOT_BUSY',
                'The interaction reservation capacity is exhausted.')
        end
        local claims = Validation.array(request.slotClaims, Limits.maximumParticipants,
            function(claim)
                return Validation.exactObject(claim, { 'objectKey', 'slotKey' }, { 'units' })
                    and Validation.identifier(claim.objectKey)
                    and Validation.text(claim.slotKey, 1, 64)
                    and (claim.units == nil or Validation.isInteger(claim.units, 1, 32))
            end)
        if not claims or #claims == 0 then
            return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                'No interaction slot was selected.')
        end
        local selected, seen = {}, {}
        local function exclusiveConflict(slot)
            if slot.concurrencyMode ~= 'exclusive' then return false end
            for reservationId, sessionId in pairs(
                    objectReservations[slot.objectKey] or {}) do
                local record = reservations[reservationId]
                if record and not record.released
                    and sessionId ~= request.sessionId then return true end
            end
            return false
        end
        -- This entire pass is intentionally yield-free: validate all claims, then publish all.
        for _, claim in ipairs(claims) do
            local id = slotId(claim.objectKey, claim.slotKey)
            if seen[id] then
                return Validation.failure('INTERACT_RESERVATION_INVALID',
                    'Duplicate slot claims are not allowed.')
            end
            seen[id] = true
            local slot = slots[id]
            if not slot or slot.ownerResource ~= request.ownerResource
                or slot.ownerEpoch ~= request.ownerEpoch
                or slot.bundleRevision ~= request.bundleRevision then
                return Validation.failure('INTERACT_SLOT_NOT_FOUND',
                    'The interaction slot is unavailable or stale.')
            end
            if slot.disabled then
                return Validation.failure('INTERACT_SLOT_DISABLED',
                    'The interaction slot is disabled.')
            end
            if exclusiveConflict(slot) then
                return Validation.failure('INTERACT_SLOT_BUSY',
                    'The Smart Object is exclusively owned by another interaction session.')
            end
            local used = 0
            for _, value in pairs(slot.reservations) do used = used + value end
            for _, value in pairs(slot.occupants) do used = used + value end
            local units = claim.units or 1
            if used + units > slot.capacity then
                return Validation.failure('INTERACT_SLOT_BUSY',
                    'The interaction slot is already reserved.')
            end
            selected[#selected + 1] = { id = id, units = units }
        end
        local objectKeys, seenObjects = {}, {}
        for _, claim in ipairs(selected) do
            local objectKey = slots[claim.id].objectKey
            if not seenObjects[objectKey] then
                seenObjects[objectKey] = true
                objectKeys[#objectKeys + 1] = objectKey
            end
        end
        table.sort(objectKeys)
        local record = {
            id = request.reservationId, sessionId = request.sessionId,
            actorKey = request.actorKey, slotIds = (function()
                local result = {}
                for _, claim in ipairs(selected) do result[#result + 1] = claim.id end
                return result
            end)(), slotUnits = (function()
                local result = {}
                for _, claim in ipairs(selected) do result[claim.id] = claim.units end
                return result
            end)(),
            expiresAt = request.expiresAt, ownerResource = request.ownerResource,
            ownerEpoch = request.ownerEpoch, bundleRevision = request.bundleRevision,
            objectKeys = objectKeys,
            state = 'RESERVED', released = false,
        }
        reservations[record.id], reservationCount = record, reservationCount + 1
        for _, objectKey in ipairs(record.objectKeys) do
            objectReservations[objectKey] = objectReservations[objectKey] or {}
            objectReservations[objectKey][record.id] = record.sessionId
        end
        for _, claim in ipairs(selected) do
            slots[claim.id].reservations[record.id] = claim.units
        end
        return Validation.copy(record), nil
    end

    function runtime.occupy(reservationId, sessionId, occupiedUntil)
        local record = reservations[reservationId]
        if not record or record.sessionId ~= sessionId or record.released
            or record.expiresAt <= now() then
            if record and record.expiresAt <= now() then releaseRecord(record) end
            return Validation.failure('INTERACT_SLOT_LOST',
                'The interaction slot reservation expired.')
        end
        if record.state == 'OCCUPIED' then return Validation.copy(record), nil end
        if occupiedUntil ~= nil and (not Validation.isInteger(occupiedUntil, 1)
            or occupiedUntil <= now()) then
            releaseRecord(record)
            return Validation.failure('INTERACT_SLOT_LOST',
                'The occupied interaction lifetime is invalid.')
        end
        for _, id in ipairs(record.slotIds) do
            local slot = slots[id]
            if not slot or slot.disabled or not slot.reservations[record.id] then
                releaseRecord(record)
                return Validation.failure('INTERACT_SLOT_LOST',
                    'The interaction slot reservation was revoked.')
            end
        end
        for _, id in ipairs(record.slotIds) do
            local slot = slots[id]
            slot.reservations[record.id] = nil
            slot.occupants[record.id] = record.slotUnits[id] or 1
        end
        if occupiedUntil ~= nil then record.expiresAt = occupiedUntil end
        record.state = 'OCCUPIED'
        return Validation.copy(record), nil
    end

    function runtime.getReservation(reservationId, sessionId)
        local record = reservations[reservationId]
        if not record or record.released
            or sessionId ~= nil and record.sessionId ~= sessionId then
            return Validation.failure('INTERACT_SLOT_LOST',
                'The interaction slot reservation is unavailable.')
        end
        if record.expiresAt <= now() then
            releaseRecord(record)
            return Validation.failure('INTERACT_SLOT_LOST',
                'The interaction slot reservation expired.')
        end
        return Validation.copy(record), nil
    end

    function runtime.release(reservationId)
        return releaseRecord(reservations[reservationId])
    end

    function runtime.setDisabled(objectKey, slotKey, disabled)
        local slot = slots[slotId(objectKey, slotKey)]
        if not slot then return Validation.failure('INTERACT_SLOT_NOT_FOUND',
            'The interaction slot was not found.') end
        slot.disabled = disabled == true
        if slot.disabled then
            local ids = {}
            for id in pairs(slot.reservations) do ids[#ids + 1] = id end
            for id in pairs(slot.occupants) do ids[#ids + 1] = id end
            for _, id in ipairs(ids) do releaseRecord(reservations[id]) end
        end
        return copySlot(slot), nil
    end

    function runtime.expire(timestamp)
        local expired = {}
        for id, record in pairs(reservations) do
            if record.expiresAt <= timestamp then expired[#expired + 1] = id end
        end
        for _, id in ipairs(expired) do releaseRecord(reservations[id]) end
        return #expired
    end

    function runtime.cleanupActor(actorKey)
        local ids = {}
        for id, record in pairs(reservations) do
            if record.actorKey == actorKey then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do releaseRecord(reservations[id]) end
        return #ids
    end

    function runtime.cleanupSession(sessionId)
        local ids = {}
        for id, record in pairs(reservations) do
            if record.sessionId == sessionId then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do releaseRecord(reservations[id]) end
        return #ids
    end

    function runtime.list(cursor, limit)
        local values = {}
        for _, slot in pairs(slots) do values[#values + 1] = copySlot(slot) end
        table.sort(values, function(left, right) return left.id < right.id end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + size - 1) do items[#items + 1] = values[index] end
        local hasMore = start + #items - 1 < #values
        return { items = items, nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end

    function runtime.inspectObject(objectKey, slotKeys)
        if not Validation.identifier(objectKey) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Smart Object slot inspection key is invalid.')
        end
        local normalized = Validation.array(slotKeys or {}, 32,
            function(key) return Validation.semanticKey(key, 64) end)
        if not normalized then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Smart Object slot inspection set is invalid.')
        end
        local items = {}
        for _, key in ipairs(normalized) do
            local slot = slots[slotId(objectKey, key)]
            if slot then items[#items + 1] = copySlot(slot) end
        end
        return { objectKey = objectKey, items = items,
            truncated = false, hasMore = false }, nil
    end

    function runtime.listReservations(cursor, limit)
        local values = {}
        for _, reservation in pairs(reservations) do
            values[#values + 1] = {
                reservationId = reservation.id,
                sessionId = reservation.sessionId,
                actorKey = reservation.actorKey,
                expiresAt = reservation.expiresAt,
                state = reservation.state,
            }
        end
        table.sort(values, function(left, right)
            return left.reservationId < right.reservationId
        end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local size = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + size - 1) do
            items[#items + 1] = values[index]
        end
        local hasMore = start + #items - 1 < #values
        return { items = items,
            nextCursor = hasMore and start + #items - 1 or nil,
            hasMore = hasMore, truncated = hasMore }
    end

    function runtime.snapshot()
        local occupied, reserved, disabled = 0, 0, 0
        for _, slot in pairs(slots) do
            local value = copySlot(slot)
            if value.state == 'OCCUPIED' then occupied = occupied + 1
            elseif value.state == 'RESERVED' then reserved = reserved + 1
            elseif value.state == 'DISABLED' then disabled = disabled + 1 end
        end
        local count = 0
        for _ in pairs(slots) do count = count + 1 end
        return { slots = count, reservations = reservationCount,
            occupied = occupied, reserved = reserved, disabled = disabled }
    end

    return runtime
end
