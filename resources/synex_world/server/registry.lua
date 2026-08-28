SynexWorldRegistry = {}

local Registry = SynexWorldRegistry
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Compiler = assert(SynexWorldCompiler, 'world compiler must be loaded first')
local SpatialIndex = assert(SynexWorldSpatialIndex, 'world spatial index must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function Registry.create(options)
    options = options or {}
    local onActivated = options.onActivated or function() end
    local onDeactivated = options.onDeactivated or function() end
    local bundles, objects, graph, objectsByKind, bundleKeys, objectKeys = {}, {},
        { roots = {}, children = {} }, {}, {}, {}
    local spatial = SpatialIndex.create(options.spatial)
    local revision, revisionCeiling, incarnationEpoch = 0, Limits.maximumRevision, nil
    local tombstones, tombstoneHead, tombstoneTail, tombstoneCount = {}, nil, nil, 0
    local maximumTombstones = Validation.isInteger(options.maximumTombstones, 1,
        Limits.maximumTombstones) and options.maximumTombstones or Limits.maximumTombstones
    local registry = {}

    local function nextRevision()
        if revision >= revisionCeiling then
            return Validation.failure('WORLD_BUNDLE_INVALID',
                'World registry revision capacity is exhausted for this resource epoch.')
        end
        return revision + 1
    end

    local function rememberTombstone(key, atRevision)
        local node = tombstones[key]
        if node then
            if node.previous then tombstones[node.previous].next = node.next
            else tombstoneHead = node.next end
            if node.next then tombstones[node.next].previous = node.previous
            else tombstoneTail = node.previous end
        else
            node = { key = key }
            tombstones[key], tombstoneCount = node, tombstoneCount + 1
        end
        node.revision, node.previous, node.next = atRevision, tombstoneTail, nil
        if tombstoneTail then tombstones[tombstoneTail].next = key else tombstoneHead = key end
        tombstoneTail = key
        while tombstoneCount > maximumTombstones do
            local oldest = tombstoneHead
            local removed = tombstones[oldest]
            tombstoneHead = removed.next
            if tombstoneHead then tombstones[tombstoneHead].previous = nil
            else tombstoneTail = nil end
            tombstones[oldest], tombstoneCount = nil, tombstoneCount - 1
        end
    end

    local function rebuild(candidateBundles)
        local candidateObjects, candidateByKind, objectCount = {}, {}, 0
        for _, bundle in pairs(candidateBundles) do
            for key, object in pairs(bundle.objects) do
                if candidateObjects[key] then
                    return Validation.failure('WORLD_BUNDLE_CONFLICT',
                        'World key is already owned by another active bundle.', false,
                        { key = key, owner = candidateObjects[key].ownerResource })
                end
                candidateObjects[key], objectCount = object, objectCount + 1
                candidateByKind[object.kind] = candidateByKind[object.kind] or {}
                candidateByKind[object.kind][#candidateByKind[object.kind] + 1] = object
                if objectCount > Limits.maximumObjects then
                    return Validation.failure('WORLD_BUNDLE_INVALID',
                        'World registry object capacity is exhausted.')
                end
            end
        end
        local candidateGraph, graphError = Compiler.validateCombined(candidateObjects, candidateBundles)
        if not candidateGraph then return nil, graphError end
        for _, entries in pairs(candidateByKind) do
            table.sort(entries, function(left, right) return left.key < right.key end)
        end
        local candidateSpatial = SpatialIndex.create(options.spatial)
        local ordered = {}
        for key in pairs(candidateObjects) do ordered[#ordered + 1] = key end
        table.sort(ordered)
        for _, key in ipairs(ordered) do
            local object = candidateObjects[key]
            if object.spatial then
                local inserted, spatialError = candidateSpatial.insert(
                    key, object, object.compiledGeometry)
                if not inserted then return nil, spatialError end
            end
        end
        local candidateBundleKeys = {}
        for key in pairs(candidateBundles) do
            candidateBundleKeys[#candidateBundleKeys + 1] = key
        end
        table.sort(candidateBundleKeys)
        return { bundles = candidateBundles, objects = candidateObjects,
            graph = candidateGraph, spatial = candidateSpatial,
            objectsByKind = candidateByKind, bundleKeys = candidateBundleKeys,
            objectKeys = ordered }
    end

    local function activate(compiled, replacing)
        local existing = bundles[compiled.key]
        if existing and not replacing then
            return Validation.failure('WORLD_BUNDLE_CONFLICT',
                'World bundle is already active.', false, { key = compiled.key })
        end
        if existing and (existing.ownerResource ~= compiled.ownerResource
            or existing.ownerEpoch > compiled.ownerEpoch) then
            return Validation.failure('STALE_RESOURCE',
                'World bundle replacement belongs to a stale or foreign owner.')
        end
        if not existing and replacing then
            return Validation.failure('WORLD_NOT_FOUND', 'World bundle is not active.')
        end
        local candidateBundles = {}
        for key, bundle in pairs(bundles) do candidateBundles[key] = bundle end
        local candidateRevision, revisionError = nextRevision()
        if not candidateRevision then return nil, revisionError end
        compiled.revision = candidateRevision
        for _, object in pairs(compiled.objects) do object.revision = candidateRevision end
        candidateBundles[compiled.key] = compiled
        local rebuilt, rebuildError = rebuild(candidateBundles)
        if not rebuilt then return nil, rebuildError end
        local previous = existing
        bundles, objects, graph, spatial, objectsByKind, bundleKeys, objectKeys, revision =
            rebuilt.bundles, rebuilt.objects, rebuilt.graph, rebuilt.spatial,
            rebuilt.objectsByKind, rebuilt.bundleKeys, rebuilt.objectKeys, candidateRevision
        if previous then
            for key in pairs(previous.objects) do rememberTombstone(key, candidateRevision) end
            onDeactivated(previous, 'replaced')
        end
        onActivated(compiled, previous ~= nil)
        return registry.bundleSnapshot(compiled)
    end

    function registry.registerBundle(candidate, ownerResource, ownerEpoch)
        if next(bundles) and registry.bundleCount() >= Limits.maximumBundles then
            return Validation.failure('WORLD_BUNDLE_INVALID', 'World bundle capacity is exhausted.')
        end
        local compiled, compileError = Compiler.compileBundle(candidate, ownerResource, ownerEpoch)
        if not compiled then return nil, compileError end
        return activate(compiled, false)
    end

    function registry.replaceBundle(candidate, ownerResource, ownerEpoch)
        local compiled, compileError = Compiler.compileBundle(candidate, ownerResource, ownerEpoch)
        if not compiled then return nil, compileError end
        return activate(compiled, true)
    end

    function registry.replaceOwnedBundle(previousKey, candidate, ownerResource, ownerEpoch)
        local previous = bundles[previousKey]
        if not previous then
            return Validation.failure('WORLD_NOT_FOUND', 'Previous World bundle is not active.')
        end
        if previous.ownerResource ~= ownerResource then
            return Validation.failure('WORLD_BUNDLE_CONFLICT',
                'Previous World bundle belongs to another resource.')
        end
        if previous.ownerEpoch ~= ownerEpoch then
            return Validation.failure('STALE_RESOURCE', 'World bundle owner epoch is stale.')
        end
        local compiled, compileError = Compiler.compileBundle(candidate, ownerResource, ownerEpoch)
        if not compiled then return nil, compileError end
        if compiled.key == previousKey then return activate(compiled, true) end
        local candidateBundles = {}
        for key, bundle in pairs(bundles) do
            if key ~= previousKey then candidateBundles[key] = bundle end
        end
        if candidateBundles[compiled.key] then
            return Validation.failure('WORLD_BUNDLE_CONFLICT',
                'Replacement World bundle key is already active.')
        end
        local candidateRevision, revisionError = nextRevision()
        if not candidateRevision then return nil, revisionError end
        compiled.revision = candidateRevision
        for _, object in pairs(compiled.objects) do object.revision = candidateRevision end
        candidateBundles[compiled.key] = compiled
        local rebuilt, rebuildError = rebuild(candidateBundles)
        if not rebuilt then return nil, rebuildError end
        for key in pairs(previous.objects) do rememberTombstone(key, candidateRevision) end
        bundles, objects, graph, spatial, objectsByKind, bundleKeys, objectKeys, revision =
            rebuilt.bundles, rebuilt.objects, rebuilt.graph, rebuilt.spatial,
            rebuilt.objectsByKind, rebuilt.bundleKeys, rebuilt.objectKeys, candidateRevision
        onDeactivated(previous, 'path_replaced')
        onActivated(compiled, true)
        return registry.bundleSnapshot(compiled)
    end

    local function deactivateBundles(initial, reason)
        local removing, removalReasons, originalOwners = {}, {}, {}
        for key, bundle in pairs(bundles) do originalOwners[bundle.ownerResource] = true end
        for key in pairs(initial) do
            removing[key], removalReasons[key] = true, reason or 'unregistered'
        end
        local rebuilt, rebuildError
        for _ = 1, Limits.maximumBundles do
            local activeOwners = {}
            for key, bundle in pairs(bundles) do
                if not removing[key] then activeOwners[bundle.ownerResource] = true end
            end
            local changed = false
            for key, bundle in pairs(bundles) do
                if not removing[key] then
                    for _, dependency in ipairs(bundle.dependencies) do
                        if originalOwners[dependency] and not activeOwners[dependency] then
                            removing[key], removalReasons[key], changed = true,
                                'dependency_unavailable', true
                            break
                        end
                    end
                end
            end
            if not changed then
                local candidateBundles = {}
                for key, bundle in pairs(bundles) do
                    if not removing[key] then candidateBundles[key] = bundle end
                end
                rebuilt, rebuildError = rebuild(candidateBundles)
                if rebuilt then break end
                local objectKey = type(rebuildError) == 'table'
                    and type(rebuildError.details) == 'table' and rebuildError.details.key or nil
                local dependent = objectKey and objects[objectKey] or nil
                if not dependent or removing[dependent.bundleKey] then return nil, rebuildError end
                removing[dependent.bundleKey] = true
                removalReasons[dependent.bundleKey] = 'dependency_unavailable'
            end
        end
        if not rebuilt then
            return Validation.failure('WORLD_BUNDLE_INVALID',
                'World dependent bundle teardown exceeded its bounded closure.')
        end
        local keys = {}
        for key in pairs(removing) do keys[#keys + 1] = key end
        table.sort(keys)
        local candidateRevision, revisionError = nextRevision()
        if not candidateRevision then return nil, revisionError end
        local removed = {}
        for _, key in ipairs(keys) do
            local bundle = bundles[key]
            for objectKey in pairs(bundle.objects) do
                rememberTombstone(objectKey, candidateRevision)
            end
            removed[#removed + 1] = {
                key = key, revision = candidateRevision, deactivated = true,
                ownerResource = bundle.ownerResource, ownerEpoch = bundle.ownerEpoch,
                reason = removalReasons[key], dependent = initial[key] ~= true,
            }
        end
        local previousBundles = bundles
        bundles, objects, graph, spatial, objectsByKind, bundleKeys, objectKeys, revision =
            rebuilt.bundles, rebuilt.objects, rebuilt.graph, rebuilt.spatial,
            rebuilt.objectsByKind, rebuilt.bundleKeys, rebuilt.objectKeys, candidateRevision
        for _, entry in ipairs(removed) do
            onDeactivated(previousBundles[entry.key], entry.reason)
        end
        return removed
    end

    function registry.unregisterBundle(key, ownerResource, ownerEpoch, reason)
        local bundle = bundles[key]
        if not bundle then return Validation.failure('WORLD_NOT_FOUND', 'World bundle is not active.') end
        if bundle.ownerResource ~= ownerResource then
            return Validation.failure('WORLD_BUNDLE_CONFLICT', 'World bundle belongs to another resource.')
        end
        if ownerEpoch and bundle.ownerEpoch ~= ownerEpoch then
            return Validation.failure('STALE_RESOURCE', 'World bundle owner epoch is stale.')
        end
        local removed, removeError = deactivateBundles({ [key] = true }, reason)
        if not removed then return nil, removeError end
        for _, entry in ipairs(removed) do
            if entry.key == key then
                return {
                    key = entry.key, revision = entry.revision, deactivated = true,
                    ownerResource = entry.ownerResource, ownerEpoch = entry.ownerEpoch,
                    reason = entry.reason, dependent = false,
                    cascaded = #removed - 1, removed = removed,
                }
            end
        end
        return Validation.failure('WORLD_BUNDLE_INVALID',
            'World bundle teardown did not include its requested root.')
    end

    function registry.unregisterOwner(ownerResource, maximumEpoch, reason)
        local keys = {}
        for key, bundle in pairs(bundles) do
            if bundle.ownerResource == ownerResource
                and (maximumEpoch == nil or bundle.ownerEpoch <= maximumEpoch) then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        if #keys == 0 then return {} end
        local initial = {}
        for _, key in ipairs(keys) do initial[key] = true end
        return deactivateBundles(initial, reason or 'owner_stopped')
    end

    function registry.resolve(reference, expectedKind)
        local normalized, referenceError = Validation.worldRef(reference, expectedKind)
        if not normalized then return nil, referenceError end
        local object = objects[normalized.key]
        if not object then
            local code = tombstones[normalized.key] and 'STALE_WORLD_REF' or 'WORLD_NOT_FOUND'
            return Validation.failure(code, code == 'STALE_WORLD_REF'
                and 'World reference points to a deactivated revision.'
                or 'World object does not exist.')
        end
        if object.revision ~= normalized.revision then
            return Validation.failure('STALE_WORLD_REF', 'World reference revision is stale.',
                false, { currentRevision = object.revision })
        end
        return object
    end

    function registry.get(key, expectedKind)
        local normalized, keyError = Validation.namespacedKey(key)
        if not normalized then return nil, keyError end
        local object = objects[normalized]
        if not object or expectedKind and object.kind ~= expectedKind then
            return Validation.failure('WORLD_NOT_FOUND', 'World object does not exist.')
        end
        return object
    end

    function registry.ref(object)
        return { kind = object.kind, key = object.key, revision = object.revision }
    end

    function registry.bindIncarnation(ownerEpoch)
        if not Validation.isInteger(ownerEpoch, 1, Limits.maximumRevisionOwnerEpoch) then
            return Validation.failure('STALE_RESOURCE',
                'World registry owner epoch cannot be represented safely.')
        end
        if incarnationEpoch ~= nil then
            if incarnationEpoch ~= ownerEpoch then
                return Validation.failure('STALE_RESOURCE',
                    'World registry is already bound to another resource epoch.')
            end
            return {
                ownerEpoch = incarnationEpoch,
                baseRevision = (incarnationEpoch - 1) * Limits.revisionIncarnationStride,
                maximumRevision = revisionCeiling,
            }
        end
        if revision ~= 0 or next(bundles) ~= nil or next(objects) ~= nil then
            return Validation.failure('STALE_RESOURCE',
                'World registry incarnation must be bound before discovery.')
        end
        incarnationEpoch = ownerEpoch
        revision = (ownerEpoch - 1) * Limits.revisionIncarnationStride
        revisionCeiling = ownerEpoch * Limits.revisionIncarnationStride - 1
        return {
            ownerEpoch = ownerEpoch,
            baseRevision = revision,
            maximumRevision = revisionCeiling,
        }
    end

    function registry.children(key, kind, limit)
        local result = {}
        for _, childKey in ipairs(graph.children[key] or {}) do
            local child = objects[childKey]
            if child and (kind == nil or child.kind == kind) then
                result[#result + 1] = child
                if #result >= (limit or Limits.maximumQueryResults) then break end
            end
        end
        return result
    end

    function registry.bundleSnapshot(bundle)
        return { schema = 1, key = bundle.key, version = bundle.version,
            ownerResource = bundle.ownerResource, ownerEpoch = bundle.ownerEpoch,
            revision = bundle.revision, objects = #bundle.orderedKeys,
            dependencies = Validation.copy(bundle.dependencies) }
    end

    local function pageStart(keys, cursor)
        local low, high, found = 1, #keys, #keys + 1
        while low <= high do
            local middle = math.floor((low + high) / 2)
            if keys[middle] > (cursor or '') then
                found, high = middle, middle - 1
            else
                low = middle + 1
            end
        end
        return found
    end

    local function objectPageStart(entries, cursor)
        local low, high, found = 1, #entries, #entries + 1
        while low <= high do
            local middle = math.floor((low + high) / 2)
            if entries[middle].key > (cursor or '') then
                found, high = middle, middle - 1
            else
                low = middle + 1
            end
        end
        return found
    end

    function registry.listBundles(cursor, limit)
        local start, maximum, result = pageStart(bundleKeys, cursor), limit or 50, {}
        local last = math.min(#bundleKeys, start + maximum - 1)
        for index = start, last do
            result[#result + 1] = registry.bundleSnapshot(bundles[bundleKeys[index]])
        end
        return result, last < #bundleKeys and result[#result].key or nil
    end

    function registry.listObjects(kind, cursor, limit)
        local entries, keys = objectsByKind[kind], objectKeys
        if kind ~= nil then
            entries = entries or {}
            keys = nil
        end
        local maximum, result = limit or 50, {}
        if keys then
            local start = pageStart(keys, cursor)
            local last = math.min(#keys, start + maximum - 1)
            for index = start, last do result[#result + 1] = objects[keys[index]] end
            return result, last < #keys and result[#result].key or nil
        end
        local start = objectPageStart(entries, cursor)
        local last = math.min(#entries, start + maximum - 1)
        for index = start, last do result[#result + 1] = entries[index] end
        return result, last < #entries and result[#result].key or nil
    end

    function registry.currentRevision() return revision end
    function registry.tombstoneCount() return tombstoneCount end
    function registry.bundleCount() return #bundleKeys end
    function registry.objectCount() return #objectKeys end
    function registry.countByKind(kind) return #(objectsByKind[kind] or {}) end
    function registry.objects() return objects end
    function registry.kindObjects(kind) return objectsByKind[kind] or {} end
    function registry.bundles() return bundles end
    function registry.graph() return graph end
    function registry.spatial() return spatial end
    return registry
end
