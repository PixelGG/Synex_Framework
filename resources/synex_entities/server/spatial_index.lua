SynexEntitySpatialIndex = {}

local function failure(code, message)
    return nil, { code = code, message = message, retryable = false }
end

local function isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value)
    return isFinite(value) and value % 1 == 0
end

local function validateEntityId(value)
    if type(value) ~= 'string' or #value < 1 or #value > 64
        or value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return failure('INVALID_ARGUMENT', 'entityId is invalid')
    end
    return value
end

local function validatePosition(value)
    if type(value) ~= 'table' then
        return failure('INVALID_ARGUMENT', 'position must be an object')
    end
    local position = {}
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        if not isFinite(value[axis]) or math.abs(value[axis]) > 20000 then
            return failure('INVALID_ARGUMENT', 'position is outside the supported world bounds')
        end
        position[axis] = value[axis] + 0.0
    end
    return position
end

local function validateBucket(value)
    if not isInteger(value) or value < 0 or value > 2147483647 then
        return failure('INVALID_ARGUMENT', 'bucket is outside the supported range')
    end
    return value
end

function SynexEntitySpatialIndex.create(options)
    options = options or {}
    local cellSize = options.cellSize or 64
    local maximumEntries = options.maximumEntries or 20000
    local maximumRadius = options.maximumRadius or 2048
    local maximumResults = options.maximumResults or 128
    local maximumScannedCells = options.maximumScannedCells or 4096
    local maximumCandidates = options.maximumCandidates or maximumEntries

    assert(isFinite(cellSize) and cellSize >= 8 and cellSize <= 512,
        'spatial cellSize must be between 8 and 512')
    assert(isInteger(maximumEntries) and maximumEntries >= 1 and maximumEntries <= 100000,
        'spatial maximumEntries is invalid')
    assert(isFinite(maximumRadius) and maximumRadius >= 1 and maximumRadius <= 20000,
        'spatial maximumRadius is invalid')
    assert(isInteger(maximumResults) and maximumResults >= 1 and maximumResults <= 1024,
        'spatial maximumResults is invalid')
    assert(isInteger(maximumScannedCells) and maximumScannedCells >= 1
        and maximumScannedCells <= 65536, 'spatial maximumScannedCells is invalid')
    assert(isInteger(maximumCandidates) and maximumCandidates >= maximumResults
        and maximumCandidates <= maximumEntries, 'spatial maximumCandidates is invalid')

    local entries = {}
    local cells = {}
    local count = 0
    local index = {}

    local function coordinates(position)
        return math.floor(position.x / cellSize), math.floor(position.y / cellSize)
    end

    local function cellKey(bucket, cellX, cellY)
        return ('%d:%d:%d'):format(bucket, cellX, cellY)
    end

    local function addToCell(entry)
        local bucket = cells[entry.cell]
        if not bucket then
            bucket = {}
            cells[entry.cell] = bucket
        end
        bucket[entry.entityId] = true
    end

    local function removeFromCell(entry)
        local bucket = cells[entry.cell]
        if not bucket then return end
        bucket[entry.entityId] = nil
        if next(bucket) == nil then cells[entry.cell] = nil end
    end

    local function normalizedEntry(entityId, position, bucket)
        local normalizedId, idError = validateEntityId(entityId)
        if not normalizedId then return nil, idError end
        local normalizedPosition, positionError = validatePosition(position)
        if not normalizedPosition then return nil, positionError end
        local normalizedBucket, bucketError = validateBucket(bucket)
        if not normalizedBucket then return nil, bucketError end
        local cellX, cellY = coordinates(normalizedPosition)
        return {
            bucket = normalizedBucket,
            cell = cellKey(normalizedBucket, cellX, cellY),
            cellX = cellX,
            cellY = cellY,
            entityId = normalizedId,
            position = normalizedPosition,
        }
    end

    function index.insert(entityId, position, bucket)
        if count >= maximumEntries then
            return failure('SPATIAL_INDEX_FULL', 'The spatial index reached its entry limit')
        end
        if entries[entityId] then
            return failure('CONFLICT', 'The entity is already present in the spatial index')
        end
        local entry, entryError = normalizedEntry(entityId, position, bucket)
        if not entry then return nil, entryError end
        entries[entry.entityId] = entry
        addToCell(entry)
        count = count + 1
        return entry
    end

    function index.update(entityId, position, bucket)
        local previous = entries[entityId]
        if not previous then
            return failure('NOT_FOUND', 'The entity is absent from the spatial index')
        end
        local replacement, replacementError = normalizedEntry(entityId, position, bucket)
        if not replacement then return nil, replacementError end
        if previous.cell ~= replacement.cell then
            removeFromCell(previous)
            addToCell(replacement)
        end
        entries[entityId] = replacement
        return replacement
    end

    function index.remove(entityId)
        local entry = entries[entityId]
        if not entry then return nil end
        removeFromCell(entry)
        entries[entityId] = nil
        count = math.max(0, count - 1)
        return entry
    end

    function index.get(entityId)
        return entries[entityId]
    end

    function index.nearby(position, radius, bucket, limit)
        local origin, positionError = validatePosition(position)
        if not origin then return nil, positionError end
        if not isFinite(radius) or radius < 0 or radius > maximumRadius then
            return failure('INVALID_ARGUMENT', 'radius is outside the supported range')
        end
        local normalizedBucket, bucketError = validateBucket(bucket)
        if not normalizedBucket then return nil, bucketError end
        limit = limit or maximumResults
        if not isInteger(limit) or limit < 1 or limit > maximumResults then
            return failure('INVALID_ARGUMENT', 'limit is outside the supported range')
        end

        local minimumX = math.floor((origin.x - radius) / cellSize)
        local maximumX = math.floor((origin.x + radius) / cellSize)
        local minimumY = math.floor((origin.y - radius) / cellSize)
        local maximumY = math.floor((origin.y + radius) / cellSize)
        local scannedCells = (maximumX - minimumX + 1) * (maximumY - minimumY + 1)
        if scannedCells > maximumScannedCells then
            return failure('QUERY_BUDGET_EXCEEDED', 'The spatial query spans too many cells')
        end

        local matches = {}
        local candidates = 0
        local radiusSquared = radius * radius
        for cellX = minimumX, maximumX do
            for cellY = minimumY, maximumY do
                local cell = cells[cellKey(normalizedBucket, cellX, cellY)]
                if cell then
                    for entityId in pairs(cell) do
                        candidates = candidates + 1
                        if candidates > maximumCandidates then
                            return failure(
                                'QUERY_BUDGET_EXCEEDED',
                                'The spatial query encountered too many candidates'
                            )
                        end
                        local entry = entries[entityId]
                        if entry then
                            local dx = entry.position.x - origin.x
                            local dy = entry.position.y - origin.y
                            local dz = entry.position.z - origin.z
                            local distanceSquared = dx * dx + dy * dy + dz * dz
                            if distanceSquared <= radiusSquared then
                                matches[#matches + 1] = {
                                    distanceSquared = distanceSquared,
                                    entityId = entityId,
                                }
                            end
                        end
                    end
                end
            end
        end

        table.sort(matches, function(left, right)
            if left.distanceSquared == right.distanceSquared then
                return left.entityId < right.entityId
            end
            return left.distanceSquared < right.distanceSquared
        end)
        local truncated = #matches > limit
        while #matches > limit do matches[#matches] = nil end
        return matches, {
            candidates = candidates,
            scannedCells = scannedCells,
            truncated = truncated,
        }
    end

    function index.count()
        return count
    end

    function index.clear()
        entries = {}
        cells = {}
        count = 0
    end

    return index
end
