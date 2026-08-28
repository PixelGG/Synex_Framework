SynexWorldSpatialIndex = {}

local SpatialIndex = SynexWorldSpatialIndex
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local function cellCoordinate(value, size) return math.floor(value / size) end
local function cellKey(x, y, z) return x .. ':' .. y .. ':' .. z end

local function coverage(candidate, size)
    local minimumX, maximumX = cellCoordinate(candidate.minX, size), cellCoordinate(candidate.maxX, size)
    local minimumY, maximumY = cellCoordinate(candidate.minY, size), cellCoordinate(candidate.maxY, size)
    local minimumZ, maximumZ = cellCoordinate(candidate.minZ, size), cellCoordinate(candidate.maxZ, size)
    local total = (maximumX - minimumX + 1) * (maximumY - minimumY + 1)
        * (maximumZ - minimumZ + 1)
    return total, minimumX, maximumX, minimumY, maximumY, minimumZ, maximumZ
end

local function addToCells(cells, key, range, parentFor)
    local keys, parents = {}, {}
    for x = range.minX, range.maxX do
        for y = range.minY, range.maxY do
            for z = range.minZ, range.maxZ do
                local current = cellKey(x, y, z)
                local members = cells[current]
                if not members then members = {}; cells[current] = members end
                members[key] = true
                keys[#keys + 1] = current
                if parentFor then parents[current] = parentFor(x, y, z) end
            end
        end
    end
    return keys, parents
end

function SpatialIndex.create(options)
    options = options or {}
    local fineSize = options.fineCellSize or Limits.fineCellSize
    local coarseSize = options.coarseCellSize or Limits.coarseCellSize
    local maximumCells = options.maximumCellsPerObject or Limits.maximumCellsPerObject
    local maximumGlobal = options.maximumGlobalObjects or Limits.maximumGlobalObjects
    local maximumCandidates = options.maximumQueryCandidates or Limits.maximumQueryCandidates
    local maximumQueryCells = options.maximumQueryCells or Limits.maximumQueryCells
    local entries, fine, coarse, global, fineByCoarse = {}, {}, {}, {}, {}
    local count, globalCount, queryCount, candidateTotal, candidateMaximum = 0, 0, 0, 0, 0
    local index = {}

    function index.insert(key, object, compiled)
        if type(key) ~= 'string' or entries[key] then
            return Validation.failure('WORLD_BUNDLE_CONFLICT', 'Spatial entry already exists.')
        end
        local total, minX, maxX, minY, maxY, minZ, maxZ = coverage(compiled.bounds, fineSize)
        local level, cells, size = 'fine', fine, fineSize
        if total > maximumCells then
            total, minX, maxX, minY, maxY, minZ, maxZ = coverage(compiled.bounds, coarseSize)
            level, cells, size = 'coarse', coarse, coarseSize
        end
        local cellKeys
        if total > maximumCells then
            if globalCount >= maximumGlobal then
                return Validation.failure('SPATIAL_INDEX_DEGRADED',
                    'Global spatial entry capacity is exhausted.')
            end
            level, globalCount = 'global', globalCount + 1
            global[key] = true
            cellKeys = {}
        else
            local fineParents
            cellKeys, fineParents = addToCells(cells, key, {
                minX = minX, maxX = maxX, minY = minY,
                maxY = maxY, minZ = minZ, maxZ = maxZ,
            }, level == 'fine' and function(x, y, z)
                return cellKey(cellCoordinate(x * fineSize, coarseSize),
                    cellCoordinate(y * fineSize, coarseSize),
                    cellCoordinate(z * fineSize, coarseSize))
            end or nil)
            if fineParents then
                for fineKey, parentKey in pairs(fineParents) do
                    local occupied = fineByCoarse[parentKey]
                    if not occupied then occupied = {}; fineByCoarse[parentKey] = occupied end
                    occupied[fineKey] = true
                end
            end
            entries[key] = { key = key, object = object, compiled = compiled,
                level = level, cells = cellKeys, cellSize = size,
                fineParents = fineParents }
        end
        if level == 'global' then
            entries[key] = { key = key, object = object, compiled = compiled,
                level = level, cells = cellKeys, cellSize = size }
        end
        count = count + 1
        return entries[key]
    end

    function index.remove(key)
        local entry = entries[key]
        if not entry then return nil end
        local cells = entry.level == 'fine' and fine or entry.level == 'coarse' and coarse or nil
        if cells then
            for _, current in ipairs(entry.cells) do
                local members = cells[current]
                if members then
                    members[key] = nil
                    if next(members) == nil then
                        cells[current] = nil
                        if entry.level == 'fine' then
                            local parentKey = entry.fineParents[current]
                            local occupied = fineByCoarse[parentKey]
                            if occupied then
                                occupied[current] = nil
                                if next(occupied) == nil then fineByCoarse[parentKey] = nil end
                            end
                        end
                    end
                end
            end
        else
            global[key] = nil
            globalCount = globalCount - 1
        end
        entries[key], count = nil, count - 1
        return entry
    end

    local function collectCell(candidates, candidateCount, cells, key)
        local members = cells[key]
        if not members then return candidateCount end
        for candidate in pairs(members) do
            if not candidates[candidate] then
                candidateCount = candidateCount + 1
                if candidateCount > maximumCandidates then return nil end
                candidates[candidate] = true
            end
        end
        return candidateCount
    end

    local function collectRange(candidates, candidateCount, cells, candidateBounds, size,
            traversedCells)
        local _, minX, maxX, minY, maxY, minZ, maxZ = coverage(candidateBounds, size)
        for x = minX, maxX do for y = minY, maxY do for z = minZ, maxZ do
            traversedCells = traversedCells + 1
            if traversedCells > maximumQueryCells then return nil end
            candidateCount = collectCell(candidates, candidateCount,
                cells, cellKey(x, y, z))
            if not candidateCount then return nil end
        end end end
        return candidateCount, traversedCells
    end

    local function collectFineRange(candidates, candidateCount, candidateBounds,
            traversedCells)
        local _, minX, maxX, minY, maxY, minZ, maxZ = coverage(candidateBounds, coarseSize)
        for x = minX, maxX do for y = minY, maxY do for z = minZ, maxZ do
            traversedCells = traversedCells + 1
            if traversedCells > maximumQueryCells then return nil end
            local occupied = fineByCoarse[cellKey(x, y, z)]
            for fineKey in pairs(occupied or {}) do
                traversedCells = traversedCells + 1
                if traversedCells > maximumQueryCells then return nil end
                candidateCount = collectCell(candidates, candidateCount, fine, fineKey)
                if not candidateCount then return nil end
            end
        end end end
        return candidateCount, traversedCells
    end

    local function collectGlobal(candidates, candidateCount)
        for key in pairs(global) do
            if not candidates[key] then
                candidateCount = candidateCount + 1
                if candidateCount > maximumCandidates then return nil end
                candidates[key] = true
            end
        end
        return candidateCount
    end

    local function finalize(candidates, candidateCount, predicate, traversedCells)
        local keys = {}
        for key in pairs(candidates) do keys[#keys + 1] = key end
        table.sort(keys)
        queryCount = queryCount + 1
        candidateTotal = candidateTotal + #keys
        candidateMaximum = math.max(candidateMaximum, #keys)
        if candidateCount > maximumCandidates or #keys ~= candidateCount then
            return Validation.failure('QUERY_LIMIT_EXCEEDED', 'Spatial candidate limit was exceeded.', true)
        end
        local result = {}
        for _, key in ipairs(keys) do
            local entry = entries[key]
            if entry and predicate(entry) then
                result[#result + 1] = entry
            end
        end
        return result, { candidates = #keys, matches = #result,
            traversedCells = traversedCells or 0, truncated = false }
    end

    function index.queryAt(point, predicate, maximumResults)
        local candidates, candidateCount = {}, 0
        candidateCount = collectCell(candidates, candidateCount, fine,
            cellKey(cellCoordinate(point.x, fineSize), cellCoordinate(point.y, fineSize),
                cellCoordinate(point.z, fineSize)))
        if candidateCount then
            candidateCount = collectCell(candidates, candidateCount, coarse,
                cellKey(cellCoordinate(point.x, coarseSize),
                    cellCoordinate(point.y, coarseSize), cellCoordinate(point.z, coarseSize)))
        end
        if candidateCount then candidateCount = collectGlobal(candidates, candidateCount) end
        if not candidateCount then
            return Validation.failure('QUERY_LIMIT_EXCEEDED',
                'Spatial candidate limit was exceeded.', true)
        end
        return finalize(candidates, candidateCount, predicate, 2)
    end

    function index.queryNearby(point, radius, predicate, maximumResults)
        if not Validation.isFinite(radius) or radius < 0 or radius > Limits.maximumQueryRadius then
            return Validation.failure('INVALID_ARGUMENT', 'Spatial query radius is invalid.')
        end
        local candidateBounds = { minX = point.x - radius, minY = point.y - radius,
            minZ = point.z - radius, maxX = point.x + radius,
            maxY = point.y + radius, maxZ = point.z + radius }
        local candidates, candidateCount, traversedCells = {}, 0, 0
        candidateCount, traversedCells = collectFineRange(candidates, candidateCount,
            candidateBounds, traversedCells)
        if candidateCount then
            candidateCount, traversedCells = collectRange(candidates, candidateCount,
                coarse, candidateBounds, coarseSize, traversedCells)
        end
        if candidateCount then candidateCount = collectGlobal(candidates, candidateCount) end
        if not candidateCount then
            return Validation.failure('QUERY_LIMIT_EXCEEDED',
                'Spatial query work limit was exceeded.', true)
        end
        local radiusSquared = radius * radius
        return finalize(candidates, candidateCount, function(entry)
            return entry.compiled and SynexWorldGeometry.distanceSquaredToBounds(
                entry.compiled, point) <= radiusSquared and predicate(entry)
        end, traversedCells)
    end

    function index.get(key) return entries[key] end
    function index.count() return count end
    function index.diagnostics(maximumHotCells)
        local hot = {}
        local function append(level, cells)
            for key, members in pairs(cells) do
                local membersCount = 0
                for _ in pairs(members) do membersCount = membersCount + 1 end
                hot[#hot + 1] = { level = level, cell = key, candidates = membersCount }
            end
        end
        append('fine', fine); append('coarse', coarse)
        table.sort(hot, function(left, right)
            return left.candidates > right.candidates
                or left.candidates == right.candidates and left.cell < right.cell
        end)
        while #hot > (maximumHotCells or 16) do hot[#hot] = nil end
        local fineCount, coarseCount = 0, 0
        for _ in pairs(fine) do fineCount = fineCount + 1 end
        for _ in pairs(coarse) do coarseCount = coarseCount + 1 end
        return { entries = count, fineCells = fineCount, coarseCells = coarseCount,
            globalEntries = globalCount, queries = queryCount,
            averageCandidates = queryCount > 0 and candidateTotal / queryCount or 0,
            maximumCandidates = candidateMaximum, hotCells = hot }
    end
    return index
end
