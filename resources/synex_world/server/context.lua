SynexWorldContext = {}

local Context = SynexWorldContext
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Geometry = assert(SynexWorldGeometry, 'world geometry must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local priorities = { region = 100, location = 200, interior = 300, room = 400, zone = 500 }
local instanceStates = { CREATING = true, READY = true, ACTIVE = true,
    DRAINING = true, CLOSED = true, FAILED = true }

function Context.create(options)
    local registry = assert(options.registry, 'world context requires a registry')
    local mapRegistry = options.mapRegistry
    local context = {}

    local contextFields = { schemaVersion = true, authority = true, revision = true,
        region = true, regions = true, location = true, interior = true, room = true,
        zones = true, instance = true }

    local function normalizeInstance(value)
        if value == nil then return nil end
        if not Validation.exactObject(value,
                { instanceId = true, revision = true, template = true, state = true })
            or type(value.instanceId) ~= 'string' or #value.instanceId < 8
            or #value.instanceId > 64
            or value.instanceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil
            or not instanceStates[value.state]
            or not Validation.isInteger(value.revision, 1, 9007199254740991) then
            return Validation.failure('OUT_OF_CONTEXT', 'World instance context is invalid.')
        end
        local template, templateError = Validation.worldRef(value.template, 'instance_template')
        if not template then return nil, templateError end
        return { instanceId = value.instanceId, revision = value.revision,
            template = template, state = value.state }
    end

    local function projectInstance(value)
        if value == nil then return nil end
        return normalizeInstance({ instanceId = value.instanceId,
            revision = value.revision, template = value.template, state = value.state })
    end

    local function normalizeReferenceList(value, kind)
        if not Validation.isDenseArray(value, 128) then
            return Validation.failure('OUT_OF_CONTEXT', 'World context reference list is invalid.')
        end
        local result, seen = {}, {}
        for index, candidate in ipairs(value) do
            local reference, referenceError = Validation.worldRef(candidate, kind)
            if not reference then return nil, referenceError end
            local identity = reference.kind .. '\0' .. reference.key .. '\0' .. reference.revision
            if seen[identity] then
                return Validation.failure('OUT_OF_CONTEXT',
                    'World context reference list contains duplicates.')
            end
            seen[identity], result[index] = true, reference
        end
        table.sort(result, function(left, right)
            return left.key < right.key
                or left.key == right.key and left.revision < right.revision
        end)
        return result
    end

    local function normalizeExpected(value)
        if not Validation.exactObject(value, contextFields)
            or value.schemaVersion ~= 1 or value.authority ~= 'VERIFIED'
            or not Validation.isInteger(value.revision, 1, 9007199254740991)
            or value.regions == nil or value.zones == nil then
            return Validation.failure('OUT_OF_CONTEXT', 'World expected context is invalid.')
        end
        local result = { schemaVersion = 1, authority = 'VERIFIED',
            revision = value.revision }
        for _, field in ipairs({ 'region', 'location', 'interior', 'room' }) do
            if value[field] ~= nil then
                local reference, referenceError = Validation.worldRef(value[field], field)
                if not reference then return nil, referenceError end
                result[field] = reference
            end
        end
        result.regions = select(1, normalizeReferenceList(value.regions, 'region'))
        if not result.regions then return Validation.failure('OUT_OF_CONTEXT',
            'World expected regions are invalid.') end
        result.zones = select(1, normalizeReferenceList(value.zones, 'zone'))
        if not result.zones then return Validation.failure('OUT_OF_CONTEXT',
            'World expected zones are invalid.') end
        if value.instance ~= nil then
            local instance, instanceError = normalizeInstance(value.instance)
            if not instance then return nil, instanceError end
            result.instance = instance
        end
        return result
    end

    local function sameReference(left, right)
        return left == nil and right == nil or left ~= nil and right ~= nil
            and left.kind == right.kind and left.key == right.key
            and left.revision == right.revision
    end

    local function sameReferenceList(left, right)
        if #left ~= #right then return false end
        for index = 1, #left do
            if not sameReference(left[index], right[index]) then return false end
        end
        return true
    end

    local function sameInstance(left, right)
        return left == nil and right == nil or left ~= nil and right ~= nil
            and left.instanceId == right.instanceId and left.revision == right.revision
            and left.state == right.state
            and sameReference(left.template, right.template)
    end

    local function available(object)
        if not mapRegistry then return true end
        local status = mapRegistry.objectAvailability(object)
        return status.available == true
    end

    local function matches(entry, filters)
        local object = entry.object
        if filters and filters.kind and object.kind ~= filters.kind then return false end
        if filters and filters.tags then
            local objectTags = {}; for _, tag in ipairs(object.tags or {}) do objectTags[tag] = true end
            for _, tag in ipairs(filters.tags) do if not objectTags[tag] then return false end end
        end
        if filters and filters.availableOnly ~= false and not available(object) then return false end
        return true
    end

    local function trim(results, metadata, limit)
        if not Validation.isInteger(limit, 1, Limits.maximumSliceObjects) then
            return Validation.failure('INVALID_ARGUMENT', 'World query limit is invalid.')
        end
        metadata = metadata or {}
        metadata.matches = #results
        metadata.truncated = #results > limit
        while #results > limit do results[#results] = nil end
        return results, metadata
    end

    function context.queryAt(point, filters, limit)
        local normalized, pointError = Validation.vector3(point, 'INVALID_ARGUMENT')
        if not normalized then return nil, pointError end
        limit = limit or Limits.maximumQueryResults
        local results, metadata = registry.spatial().queryAt(normalized, function(entry)
            return matches(entry, filters) and Geometry.contains(entry.compiled, normalized, 0)
        end, limit)
        if not results then return nil, metadata end
        table.sort(results, function(left, right)
            local leftPriority, rightPriority = priorities[left.object.kind] or 0,
                priorities[right.object.kind] or 0
            return leftPriority > rightPriority
                or leftPriority == rightPriority and left.key < right.key
        end)
        results, metadata = trim(results, metadata, limit)
        if not results then return nil, metadata end
        local objects = {}; for index, entry in ipairs(results) do objects[index] = entry.object end
        return objects, metadata
    end

    function context.queryNearby(point, radius, filters, limit)
        local normalized, pointError = Validation.vector3(point, 'INVALID_ARGUMENT')
        if not normalized then return nil, pointError end
        local results, metadata = registry.spatial().queryNearby(normalized, radius,
            function(entry) return matches(entry, filters) end,
            limit or Limits.maximumQueryResults)
        if not results then return nil, metadata end
        table.sort(results, function(left, right)
            local leftDistance = Geometry.distanceSquaredToBounds(left.compiled, normalized)
            local rightDistance = Geometry.distanceSquaredToBounds(right.compiled, normalized)
            return leftDistance < rightDistance
                or leftDistance == rightDistance and left.key < right.key
        end)
        local queryLimit = limit or Limits.maximumQueryResults
        results, metadata = trim(results, metadata, queryLimit)
        if not results then return nil, metadata end
        local objects = {}
        for index, entry in ipairs(results) do
            objects[index] = { object = entry.object,
                distance = math.sqrt(Geometry.distanceSquaredToBounds(entry.compiled, normalized)) }
        end
        return objects, metadata
    end

    function context.resolve(point, instanceRef)
        local objects, metadata = context.queryAt(point, { availableOnly = true }, 128)
        if not objects then return nil, metadata end
        if metadata and metadata.truncated then
            return Validation.failure('QUERY_LIMIT_EXCEEDED',
                'World context overlap limit was exceeded.', true,
                { candidates = metadata.candidates })
        end
        local instance, instanceError = projectInstance(instanceRef)
        if instanceRef ~= nil and not instance then return nil, instanceError end
        local result = { schemaVersion = 1, authority = 'VERIFIED', revision = registry.currentRevision(),
            regions = {}, zones = {}, instance = instance }
        local primary, matchingRegions
        for _, object in ipairs(objects) do
            local reference = registry.ref(object)
            if object.kind == 'region' then
                matchingRegions = matchingRegions or {}
                matchingRegions[#matchingRegions + 1] = object
                result.regions[#result.regions + 1] = reference
            elseif (object.kind == 'location' or object.kind == 'interior'
                    or object.kind == 'room') and primary == nil then
                primary = object
            elseif object.kind == 'zone' then
                result.zones[#result.zones + 1] = reference
            end
        end
        table.sort(result.regions, function(a, b) return a.key < b.key end)
        table.sort(result.zones, function(a, b) return a.key < b.key end)
        local registryObjects = registry.objects()
        local visited, current = {}, primary
        while current and not visited[current.key] do
            visited[current.key] = true
            if current.kind == 'room' then result.room = registry.ref(current)
            elseif current.kind == 'interior' then result.interior = registry.ref(current)
            elseif current.kind == 'location' then result.location = registry.ref(current)
            elseif current.kind == 'region' and result.region == nil then
                result.region = registry.ref(current)
            end
            current = current.parent and registryObjects[current.parent] or nil
        end
        if result.region == nil and matchingRegions then
            local depths = {}
            local function regionDepth(region)
                if depths[region.key] then return depths[region.key] end
                local chain, seen, cursor = {}, {}, region
                while cursor and cursor.kind == 'region' and not depths[cursor.key]
                    and not seen[cursor.key] do
                    seen[cursor.key] = true
                    chain[#chain + 1] = cursor
                    cursor = cursor.parent and registryObjects[cursor.parent] or nil
                end
                local depth = cursor and depths[cursor.key] or 0
                for index = #chain, 1, -1 do
                    depth = depth + 1
                    depths[chain[index].key] = depth
                end
                return depths[region.key]
            end
            local selected, selectedDepth
            for _, region in ipairs(matchingRegions) do
                local depth = regionDepth(region)
                if selected == nil or depth > selectedDepth
                    or depth == selectedDepth and region.key < selected.key then
                    selected, selectedDepth = region, depth
                end
            end
            result.region = registry.ref(selected)
        end
        return result
    end

    function context.verify(expected, point, instanceRef)
        local normalized, expectedError = normalizeExpected(expected)
        if not normalized then return nil, expectedError end
        if normalized.revision ~= registry.currentRevision() then
            return Validation.failure('OUT_OF_CONTEXT', 'World context revision is stale.')
        end
        local actual, actualError = context.resolve(point, instanceRef)
        if not actual then return nil, actualError end
        for _, field in ipairs({ 'region', 'location', 'interior', 'room' }) do
            if not sameReference(normalized[field], actual[field]) then
                return Validation.failure('OUT_OF_CONTEXT', 'World context does not match server position.',
                    false, { field = field })
            end
        end
        if not sameReferenceList(normalized.regions, actual.regions) then
            return Validation.failure('OUT_OF_CONTEXT',
                'World context does not match server regions.', false, { field = 'regions' })
        end
        if not sameReferenceList(normalized.zones, actual.zones) then
            return Validation.failure('OUT_OF_CONTEXT',
                'World context does not match server zones.', false, { field = 'zones' })
        end
        if not sameInstance(normalized.instance, actual.instance) then
            return Validation.failure('OUT_OF_CONTEXT',
                'World context does not match server instance.', false, { field = 'instance' })
        end
        return { valid = true, context = actual }
    end
    return context
end
