SynexWorldMapRegistry = {}

local MapRegistry = SynexWorldMapRegistry
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function MapRegistry.create(options)
    local registry = assert(options.registry, 'world map registry requires a registry')
    local getResourceState = assert(options.getResourceState,
        'world map registry requires GetResourceState')
    local cache, generation = {}, 0
    local impactCache, impactRevision = {}, -1
    local impactAccess, impactClock, impactCacheSize = {}, 0, 0
    local dependencySeeds, availabilityCache = {}, {}
    local dependencyRevision, availabilityGeneration = -1, -1
    local maximumAvailabilityReasons = 64
    local maximumImpactCacheEntries = 256
    local summary = { total = 0, available = 0, unavailable = 0,
        requiredUnavailable = 0, generation = 0 }
    local iplIndex, iplIndexRevision = { global = {} }, -1
    local maps = {}

    local function currentRevision()
        return type(registry.currentRevision) == 'function'
            and registry.currentRevision() or 0
    end

    local function kindObjects(kind)
        if type(registry.kindObjects) == 'function' then return registry.kindObjects(kind) end
        local result = {}
        for _, object in pairs(registry.objects()) do
            if object.kind == kind then result[#result + 1] = object end
        end
        table.sort(result, function(left, right) return left.key < right.key end)
        return result
    end

    local function refreshSummary()
        local nextSummary = { total = 0, available = 0, unavailable = 0,
            requiredUnavailable = 0, generation = generation }
        for _, status in pairs(cache) do
            nextSummary.total = nextSummary.total + 1
            if status.available then nextSummary.available = nextSummary.available + 1
            elseif status.required then
                nextSummary.requiredUnavailable = nextSummary.requiredUnavailable + 1
            end
        end
        nextSummary.unavailable = nextSummary.total - nextSummary.available
        summary = nextSummary
    end

    local function refreshIplIndex()
        local revision = currentRevision()
        if iplIndexRevision == revision then return end
        local global = {}
        for _, bundle in ipairs(kindObjects('ipl_bundle')) do
            if bundle.scope == 'global' then global[#global + 1] = bundle.key end
        end
        iplIndex, iplIndexRevision = { global = global }, revision
    end

    local function addDependencySeed(objectKey, packageKey)
        if type(objectKey) ~= 'string' or type(packageKey) ~= 'string' then return end
        local seeds = dependencySeeds[objectKey]
        if not seeds then seeds = {}; dependencySeeds[objectKey] = seeds end
        seeds[packageKey] = true
    end

    local function ensureDependencyIndex()
        local revision = currentRevision()
        if dependencyRevision == revision then return end
        dependencySeeds, availabilityCache = {}, {}
        local objects = registry.objects()
        for key, object in pairs(objects) do
            for _, packageKey in ipairs(object.mapPackages or {}) do
                addDependencySeed(key, packageKey)
            end
            if object.kind == 'map_package' then
                addDependencySeed(key, key)
                for _, locationKey in ipairs(object.locations or {}) do
                    addDependencySeed(locationKey, key)
                end
            end
        end
        dependencyRevision, availabilityGeneration = revision, generation
    end

    local function sameStatus(left, right)
        if not left or not right or left.available ~= right.available
            or left.required ~= right.required or left.state ~= right.state
            or left.resourceName ~= right.resourceName or #left.reasons ~= #right.reasons then
            return false
        end
        for index, reason in ipairs(left.reasons) do
            local candidate = right.reasons[index]
            if not candidate or reason.code ~= candidate.code
                or reason.resource ~= candidate.resource or reason.state ~= candidate.state then
                return false
            end
        end
        return true
    end

    local function packageStatus(package)
        local state = getResourceState(package.resourceName)
        local reasons = {}
        if state ~= package.expectedResourceState then
            reasons[#reasons + 1] = { code = 'MAP_RESOURCE_UNAVAILABLE',
                resource = package.resourceName, state = tostring(state) }
        end
        for _, dependency in ipairs(package.dependencies or {}) do
            local dependencyState = getResourceState(dependency)
            if dependencyState ~= 'started' then
                reasons[#reasons + 1] = { code = 'MAP_RESOURCE_UNAVAILABLE',
                    resource = dependency, state = tostring(dependencyState) }
            end
        end
        return { key = package.key, resourceName = package.resourceName,
            available = #reasons == 0, required = package.required,
            state = state, reasons = reasons, generation = generation }
    end

    function maps.refresh()
        ensureDependencyIndex()
        local nextCache, changed = {}, false
        for _, object in ipairs(kindObjects('map_package')) do
            nextCache[object.key] = packageStatus(object)
            if not sameStatus(cache[object.key], nextCache[object.key]) then changed = true end
        end
        for key in pairs(cache) do if not nextCache[key] then changed = true end end
        if changed then
            generation = generation + 1
            availabilityCache = {}
            availabilityGeneration = generation
        end
        cache = nextCache
        for _, status in pairs(cache) do status.generation = generation end
        refreshSummary()
        return maps.summary()
    end

    function maps.get(key)
        if not cache[key] then
            local object = registry.get(key, 'map_package')
            if not object then return Validation.failure('WORLD_NOT_FOUND', 'Map package does not exist.') end
            cache[key] = packageStatus(object)
            refreshSummary()
        end
        return Validation.copy(cache[key])
    end

    function maps.objectAvailability(object)
        ensureDependencyIndex()
        if availabilityGeneration ~= generation then
            availabilityCache, availabilityGeneration = {}, generation
        end

        local objects = registry.objects()
        local function packageAvailability(key)
            local status = cache[key]
            if not status then
                local package = registry.get(key, 'map_package')
                status = package and packageStatus(package) or { available = false,
                    reasons = { { code = 'MAP_PACKAGE_UNAVAILABLE', resource = key } } }
                cache[key] = status
                refreshSummary()
            end
            return status
        end
        local function appendReason(reasons, seen, reason)
            local identity = table.concat({ tostring(reason.code), tostring(reason.resource),
                tostring(reason.state) }, '\0')
            if seen[identity] then return false end
            seen[identity] = true
            if #reasons >= maximumAvailabilityReasons then return true end
            reasons[#reasons + 1] = Validation.copy(reason)
            return false
        end
        local function directAvailability(candidate)
            local reasons, seen, truncated = {}, {}, false
            for _, packageKey in ipairs(candidate.mapPackages or {}) do
                local status = packageAvailability(packageKey)
                if not status.available then
                    for _, reason in ipairs(status.reasons or {}) do
                        truncated = appendReason(reasons, seen, reason) or truncated
                    end
                end
            end
            return { available = #reasons == 0 and not truncated,
                reasons = reasons, truncated = truncated }
        end

        if type(object) ~= 'table' or type(object.key) ~= 'string'
            or objects[object.key] == nil then
            return directAvailability(object or {})
        end
        local function publicAvailability(value)
            return { available = value.available == true,
                reasons = Validation.copy(value.reasons or {}),
                truncated = value.truncated == true }
        end
        local cached = availabilityCache[object.key]
        if cached then return publicAvailability(cached) end

        local path, seenPath, current = {}, {}, object
        while current and not availabilityCache[current.key] do
            if seenPath[current.key] or #path >= Limits.maximumObjects then
                return { available = false, reasons = { {
                    code = 'WORLD_DEPENDENCY_MISSING', resource = current.key,
                } }, truncated = true }
            end
            seenPath[current.key] = true
            path[#path + 1] = current
            current = current.parent and objects[current.parent] or nil
        end

        local inherited = current and availabilityCache[current.key]
            or { available = true, reasons = {}, reasonKeys = {}, truncated = false }
        for index = #path, 1, -1 do
            local candidate = path[index]
            local reasons, reasonKeys = inherited.reasons, inherited.reasonKeys
            local ownsReasons, ownsReasonKeys = false, false
            local truncated = inherited.truncated == true
            local packageKeys = {}
            for packageKey in pairs(dependencySeeds[candidate.key] or {}) do
                packageKeys[#packageKeys + 1] = packageKey
            end
            table.sort(packageKeys)
            local available = inherited.available == true
            for _, packageKey in ipairs(packageKeys) do
                local status = packageAvailability(packageKey)
                if not status.available then
                    available = false
                    for _, reason in ipairs(status.reasons or {}) do
                        local identity = table.concat({ tostring(reason.code),
                            tostring(reason.resource), tostring(reason.state) }, '\0')
                        if not reasonKeys[identity] then
                            if #reasons >= maximumAvailabilityReasons then
                                truncated = true
                            else
                                if not ownsReasons then
                                    local copied = {}
                                    for reasonIndex, inheritedReason in ipairs(reasons) do
                                        copied[reasonIndex] = inheritedReason
                                    end
                                    reasons, ownsReasons = copied, true
                                end
                                if not ownsReasonKeys then
                                    local copied = {}
                                    for key, present in pairs(reasonKeys) do copied[key] = present end
                                    reasonKeys, ownsReasonKeys = copied, true
                                end
                                reasonKeys[identity] = true
                                reasons[#reasons + 1] = Validation.copy(reason)
                            end
                        end
                    end
                end
            end
            inherited = { available = available and not truncated,
                reasons = reasons, reasonKeys = reasonKeys, truncated = truncated }
            availabilityCache[candidate.key] = inherited
        end
        return publicAvailability(availabilityCache[object.key])
    end

    local function referencesPackage(object, packageKey)
        for _, reference in ipairs(object.mapPackages or {}) do
            if reference == packageKey then return true end
        end
        return false
    end

    local function impactCategory(source, maximumSamples)
        local keys = {}
        for key in pairs(source) do keys[#keys + 1] = key end
        table.sort(keys)
        local samples = {}
        for index = 1, math.min(#keys, maximumSamples) do samples[index] = keys[index] end
        return { count = #keys, samples = samples, truncated = #keys > #samples }
    end

    local function resetImpactCache(registryRevision)
        if impactRevision == registryRevision then return end
        impactCache, impactAccess = {}, {}
        impactClock, impactCacheSize, impactRevision = 0, 0, registryRevision
    end

    local function projectImpact(cached, maximumSamples)
        impactClock = impactClock + 1
        impactAccess[cached.packageKey] = impactClock
        local result = Validation.copy(cached)
        for _, category in ipairs({ 'bundles', 'locations', 'anchors', 'doors' }) do
            local projection = result[category]
            while #projection.samples > maximumSamples do
                projection.samples[#projection.samples] = nil
            end
            projection.truncated = projection.count > #projection.samples
        end
        result.truncated = result.traversalTruncated or result.bundles.truncated
            or result.locations.truncated or result.anchors.truncated
            or result.doors.truncated
        return result
    end

    function maps.cachedImpact(key, maximumSamples)
        local package, packageError = registry.get(key, 'map_package')
        if not package then return nil, packageError end
        maximumSamples = maximumSamples or 8
        if not Validation.isInteger(maximumSamples, 1, 32) then
            return Validation.failure('INVALID_ARGUMENT',
                'Map package impact sample bound is invalid.')
        end
        resetImpactCache(currentRevision())
        local cached = impactCache[package.key]
        if not cached then return nil end
        return projectImpact(cached, maximumSamples)
    end

    -- Impact analysis is a cold-path diagnostic. Both its traversal and its output are
    -- bounded independently: the registry cannot exceed maximumObjects and each
    -- category exposes only a small, caller-bounded sample.
    function maps.impact(key, maximumSamples)
        local package, packageError = registry.get(key, 'map_package')
        if not package then return nil, packageError end
        maximumSamples = maximumSamples or 8
        if not Validation.isInteger(maximumSamples, 1, 32) then
            return Validation.failure('INVALID_ARGUMENT',
                'Map package impact sample bound is invalid.')
        end

        local registryRevision = currentRevision()
        resetImpactCache(registryRevision)
        local cached = impactCache[package.key]
        if cached then return projectImpact(cached, maximumSamples) end

        local affected = { bundles = {}, locations = {}, anchors = {}, doors = {} }
        local queued, visited, queue = {}, {}, {}
        local function addBundle(object)
            if object and object.bundleKey then affected.bundles[object.bundleKey] = true end
        end
        local function enqueue(reference)
            if reference and not queued[reference] then
                queued[reference] = true
                queue[#queue + 1] = reference
            end
        end
        local function include(object)
            if not object then return end
            addBundle(object)
            if object.kind == 'location' then affected.locations[object.key] = true
            elseif object.kind == 'anchor' then affected.anchors[object.key] = true
            elseif object.kind == 'door' then affected.doors[object.key] = true end
        end

        addBundle(package)
        for _, locationKey in ipairs(package.locations or {}) do enqueue(locationKey) end

        local scanned = 0
        for _, object in pairs(registry.objects()) do
            scanned = scanned + 1
            if referencesPackage(object, package.key) then
                include(object)
                enqueue(object.key)
            end
        end

        local graph = registry.graph()
        local cursor, traversed = 1, 0
        while cursor <= #queue and traversed < Limits.maximumObjects do
            local current = queue[cursor]
            cursor = cursor + 1
            if not visited[current] then
                visited[current] = true
                traversed = traversed + 1
                include(registry.objects()[current])
                for _, child in ipairs(graph.children[current] or {}) do enqueue(child) end
            end
        end
        local traversalTruncated = cursor <= #queue

        local result = {
            packageKey = package.key,
            revision = registryRevision,
            scannedObjects = scanned,
            traversedObjects = traversed,
            bundles = impactCategory(affected.bundles, 32),
            locations = impactCategory(affected.locations, 32),
            anchors = impactCategory(affected.anchors, 32),
            doors = impactCategory(affected.doors, 32),
            traversalTruncated = traversalTruncated,
        }
        result.truncated = traversalTruncated or result.bundles.truncated
            or result.locations.truncated or result.anchors.truncated or result.doors.truncated
        if impactCacheSize >= maximumImpactCacheEntries then
            local oldestKey, oldestAccess
            for cachedKey in pairs(impactCache) do
                local accessed = impactAccess[cachedKey] or 0
                if oldestAccess == nil or accessed < oldestAccess
                    or accessed == oldestAccess and cachedKey < oldestKey then
                    oldestKey, oldestAccess = cachedKey, accessed
                end
            end
            if oldestKey then
                impactCache[oldestKey], impactAccess[oldestKey] = nil, nil
                impactCacheSize = impactCacheSize - 1
            end
        end
        impactClock = impactClock + 1
        impactCache[package.key], impactAccess[package.key] = result, impactClock
        impactCacheSize = impactCacheSize + 1
        return projectImpact(result, maximumSamples)
    end

    function maps.clientRequirements(objects, instance)
        refreshIplIndex()
        local bundleKeys, seen = {}, {}
        for _, key in ipairs(iplIndex.global) do
            seen[key] = true
            bundleKeys[#bundleKeys + 1] = key
        end
        for _, object in ipairs(objects) do
            for _, key in ipairs(object.iplBundles or {}) do
                local bundle = registry.get(key, 'ipl_bundle')
                local permitted = bundle and (bundle.scope == 'global'
                    or bundle.scope == 'context'
                    or bundle.scope == 'instance' and instance ~= nil)
                if permitted and not seen[key] then
                    seen[key] = true
                    bundleKeys[#bundleKeys + 1] = key
                end
            end
        end
        table.sort(bundleKeys)
        local ipls, interiorSets, iplsByName, setsByKey = {}, {}, {}, {}
        for _, key in ipairs(bundleKeys) do
            local bundle = registry.get(key, 'ipl_bundle')
            if bundle then
                for _, ipl in ipairs(bundle.ipls) do
                    local requirement = iplsByName[ipl]
                    if requirement then
                        requirement.refCount = requirement.refCount + 1
                        if requirement.refCount > Limits.maximumClientRequirementRefCount then
                            return nil, nil, select(2, Validation.failure('QUERY_LIMIT_EXCEEDED',
                                'World client IPL reference count exceeded its bound.', true,
                                { name = ipl, maximum = Limits.maximumClientRequirementRefCount }))
                        end
                    else
                        if #ipls >= Limits.maximumClientIpls then
                            return nil, nil, select(2, Validation.failure('QUERY_LIMIT_EXCEEDED',
                                'World client IPL requirement limit was exceeded.', true,
                                { maximum = Limits.maximumClientIpls }))
                        end
                        requirement = { name = ipl, refCount = 1 }
                        iplsByName[ipl], ipls[#ipls + 1] = requirement, requirement
                    end
                end
                for _, set in ipairs(bundle.interiorSets or {}) do
                    local setKey = set.interiorId .. ':' .. set.name
                    local requirement = setsByKey[setKey]
                    if requirement then
                        if requirement.color ~= set.color then
                            return nil, nil, select(2, Validation.failure('WORLD_BUNDLE_CONFLICT',
                                'World interior entity set requirements disagree on color.', false,
                                { interiorId = set.interiorId, name = set.name }))
                        end
                        requirement.refCount = requirement.refCount + 1
                        if requirement.refCount > Limits.maximumClientRequirementRefCount then
                            return nil, nil, select(2, Validation.failure('QUERY_LIMIT_EXCEEDED',
                                'World client interior entity set reference count exceeded its bound.',
                                true, { interiorId = set.interiorId, name = set.name,
                                    maximum = Limits.maximumClientRequirementRefCount }))
                        end
                    else
                        if #interiorSets >= Limits.maximumClientInteriorSets then
                            return nil, nil, select(2, Validation.failure('QUERY_LIMIT_EXCEEDED',
                                'World client interior entity set requirement limit was exceeded.', true,
                                { maximum = Limits.maximumClientInteriorSets }))
                        end
                        requirement = Validation.copy(set)
                        requirement.refCount = 1
                        setsByKey[setKey], interiorSets[#interiorSets + 1] = requirement, requirement
                    end
                end
            end
        end
        table.sort(ipls, function(a, b) return a.name < b.name end)
        table.sort(interiorSets, function(a, b)
            return a.interiorId < b.interiorId
                or a.interiorId == b.interiorId and a.name < b.name
        end)
        return ipls, interiorSets
    end

    function maps.summary()
        return Validation.copy(summary)
    end
    return maps
end
