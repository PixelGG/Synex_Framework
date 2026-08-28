SynexWorldBundleLoader = {}

local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function SynexWorldBundleLoader.create(options)
    local registry = assert(options.registry, 'world bundle loader requires registry')
    local getRuntimeSnapshot = assert(options.getRuntimeSnapshot,
        'world bundle loader requires Core runtime discovery')
    local checkCapability = assert(options.checkCapability,
        'world bundle loader requires delegated capability checks')
    local loadResourceFile = assert(options.loadResourceFile,
        'world bundle loader requires resource file access')
    local decode = assert(options.decode, 'world bundle loader requires JSON decoding')
    local getResourceState = assert(options.getResourceState,
        'world bundle loader requires resource state')
    local foundation = assert(options.foundation, 'world bundle loader requires foundation')
    local observability = assert(options.observability, 'world bundle loader requires observability')
    local paths = {}
    local loader = {}

    local function forgetRemoved(removed)
        local removedKeys, resources = {}, {}
        for _, entry in ipairs(removed or {}) do removedKeys[entry.key] = true end
        for resourceName in pairs(paths) do resources[#resources + 1] = resourceName end
        table.sort(resources)
        for _, resourceName in ipairs(resources) do
            local resourcePaths = paths[resourceName]
            if resourcePaths then
                for path, key in pairs(resourcePaths) do
                    if removedKeys[key] then resourcePaths[path] = nil end
                end
                if next(resourcePaths) == nil then paths[resourceName] = nil end
            end
        end
    end

    local function validPath(path)
        if type(path) ~= 'string' or #path < 18 or #path > 240 then return false end
        if path:match('^world/[A-Za-z0-9._/-]+%.world%.json$') == nil
            or path:find('\\', 1, true) ~= nil or path:find('//', 1, true) ~= nil then
            return false
        end
        for segment in path:gmatch('[^/]+') do
            if segment == '.' or segment == '..' then return false end
        end
        return true
    end

    local function resourceRecord(resourceName)
        local snapshot, snapshotError = getRuntimeSnapshot()
        if not snapshot then return nil, snapshotError end
        for _, resource in ipairs(snapshot.resources or {}) do
            if resource.name == resourceName then return resource end
        end
        return Validation.failure('WORLD_DEPENDENCY_MISSING',
            'World bundle owner is not present in the Core resource registry.', true)
    end

    local function declared(record, path)
        for _, candidate in ipairs(record.manifest and record.manifest.worldBundles or {}) do
            if candidate == path then return true end
        end
        return false
    end

    function loader.load(resourceName, path, replace, expectedEpoch, context)
        if not validPath(path) then
            return Validation.failure('WORLD_BUNDLE_INVALID', 'World bundle path is invalid.')
        end
        local record, recordError = resourceRecord(resourceName)
        if not record then return nil, recordError end
        if record.state ~= 'STARTED' or getResourceState(resourceName) ~= 'started' then
            return Validation.failure('WORLD_DEPENDENCY_MISSING',
                'World bundle owner resource is not started.', true)
        end
        if expectedEpoch and record.epoch ~= expectedEpoch then
            return Validation.failure('STALE_RESOURCE', 'World bundle owner epoch changed.')
        end
        if not declared(record, path) then
            return Validation.failure('WORLD_BUNDLE_INVALID',
                'World bundle path is not declared by its owner manifest.')
        end
        local allowed, capabilityError = checkCapability(resourceName,
            'synex.world.bundle.register', 'world bundle activation')
        if not allowed then return nil, capabilityError end
        local encoded = loadResourceFile(resourceName, path)
        if type(encoded) ~= 'string' or #encoded < 2 or #encoded > Limits.maximumBundleBytes then
            return Validation.failure('WORLD_BUNDLE_INVALID', 'World bundle file is missing or oversized.')
        end
        local decodeOk, candidate = pcall(decode, encoded)
        if not decodeOk or not Validation.isPlainTable(candidate) then
            return Validation.failure('WORLD_BUNDLE_INVALID', 'World bundle JSON is invalid.')
        end
        local previousKey = paths[resourceName] and paths[resourceName][path]
        local result, activateError
        if replace or previousKey then
            if previousKey then
                result, activateError = registry.replaceOwnedBundle(
                    previousKey, candidate, resourceName, record.epoch)
            else
                return Validation.failure('WORLD_NOT_FOUND',
                    'World bundle path is not active and cannot be replaced.')
            end
        else
            result, activateError = registry.registerBundle(candidate, resourceName, record.epoch)
        end
        if not result then
            observability.increment('bundle_validation_failure_total', {}, 1)
            return nil, activateError
        end
        paths[resourceName] = paths[resourceName] or {}
        paths[resourceName][path] = result.key
        observability.audit('world.bundle_activated', 'world_bundle', result.key,
            { revision = result.revision, owner = resourceName }, context)
        return result
    end

    function loader.discoverResource(resourceName, context, retryOnly)
        local record, recordError = resourceRecord(resourceName)
        if not record then return nil, recordError end
        local declaredPaths = record.manifest and record.manifest.worldBundles or {}
        local expected, loaded, activated, failures = {}, 0, 0, {}
        for _, path in ipairs(declaredPaths) do expected[path] = true end
        local tracked = {}
        for path, key in pairs(paths[resourceName] or {}) do
            tracked[#tracked + 1] = { path = path, key = key }
        end
        table.sort(tracked, function(left, right) return left.path < right.path end)
        for _, entry in ipairs(tracked) do
            local active = registry.bundles()[entry.key]
            if not active then
                if paths[resourceName] then paths[resourceName][entry.path] = nil end
            elseif not expected[entry.path] then
                local removed, removeError = registry.unregisterBundle(
                    entry.key, resourceName, record.epoch, 'manifest_changed')
                if removed then forgetRemoved(removed.removed)
                else failures[#failures + 1] = {
                    path = entry.path, code = removeError.code,
                } end
            end
        end
        for _, path in ipairs(declaredPaths) do
            local activeKey = paths[resourceName] and paths[resourceName][path]
            if activeKey and not registry.bundles()[activeKey] then
                paths[resourceName][path], activeKey = nil, nil
            end
            local active = activeKey ~= nil
            if retryOnly and active then
                loaded = loaded + 1
            else
                local result, loadError = loader.load(resourceName, path,
                    active, record.epoch, context)
                if result then
                    loaded = loaded + 1
                    if not active then activated = activated + 1 end
                else failures[#failures + 1] = { path = path, code = loadError.code } end
            end
        end
        return { resource = resourceName, loaded = loaded,
            activated = activated, failures = failures }
    end

    function loader.discoverAll(context)
        local snapshot, snapshotError = getRuntimeSnapshot()
        if not snapshot then return nil, snapshotError end
        local pending = {}
        for _, resource in ipairs(snapshot.resources or {}) do
            if resource.state == 'STARTED' and resource.manifest
                and type(resource.manifest.worldBundles) == 'table'
                and #resource.manifest.worldBundles > 0 then pending[#pending + 1] = resource.name end
        end
        table.sort(pending)
        local reports, remaining = {}, pending
        for attempt = 1, 64 do
            local retry, progressed = {}, false
            for _, resourceName in ipairs(remaining) do
                local report, discoverError = loader.discoverResource(
                    resourceName, context, true)
                if report and #report.failures == 0 then
                    reports[#reports + 1] = report
                    progressed = true
                else
                    retry[#retry + 1] = resourceName
                    if report and (tonumber(report.activated) or 0) > 0 then
                        progressed = true
                    end
                end
            end
            remaining = retry
            if #remaining == 0 or not progressed then break end
        end
        return { resources = reports, unresolved = remaining }
    end

    function loader.ownerStopped(resourceName, ownerEpoch, context)
        local removed, removeError = registry.unregisterOwner(
            resourceName, ownerEpoch, 'owner_stopped')
        if not removed then return nil, removeError end
        forgetRemoved(removed)
        local dependents = 0
        for _, bundle in ipairs(removed) do
            if bundle.dependent then dependents = dependents + 1 end
            observability.audit('world.bundle_deactivated', 'world_bundle', bundle.key,
                { revision = bundle.revision, owner = bundle.ownerResource,
                    reason = bundle.reason }, context)
        end
        return { count = #removed, dependents = dependents, removed = removed }
    end

    function loader.unload(resourceName, bundleKey, ownerEpoch, context)
        local path = loader.pathForBundle(resourceName, bundleKey)
        if not path then
            return Validation.failure('WORLD_NOT_FOUND',
                'World bundle is not registered from an owned manifest path.')
        end
        local removed, removeError = registry.unregisterBundle(
            bundleKey, resourceName, ownerEpoch, 'caller_unregistered')
        if not removed then return nil, removeError end
        forgetRemoved(removed.removed)
        for _, entry in ipairs(removed.removed or { removed }) do
            observability.audit('world.bundle_deactivated', 'world_bundle', entry.key,
                { revision = entry.revision, owner = entry.ownerResource,
                    reason = entry.reason }, context)
        end
        return removed
    end

    function loader.pathForBundle(resourceName, bundleKey)
        for path, key in pairs(paths[resourceName] or {}) do if key == bundleKey then return path end end
        return nil
    end
    return loader
end
