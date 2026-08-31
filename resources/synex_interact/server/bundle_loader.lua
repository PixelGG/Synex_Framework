SynexInteractBundleLoader = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractBundleLoader.create(options)
    options = options or {}
    local registry = assert(options.registry, 'bundle loader requires registry')
    local getRuntimeSnapshot = assert(options.getRuntimeSnapshot,
        'bundle loader requires Core runtime discovery')
    local checkCapability = assert(options.checkCapability,
        'bundle loader requires delegated capability checks')
    local loadResourceFile = assert(options.loadResourceFile,
        'bundle loader requires resource file access')
    local decode = assert(options.decode, 'bundle loader requires JSON decoding')
    local getResourceState = assert(options.getResourceState,
        'bundle loader requires resource state')
    local selfResource = assert(options.resourceName, 'bundle loader requires resource name')
    local observability = assert(options.observability, 'bundle loader requires observability')
    local paths, failures, failureCount, failureOverflow = {}, {}, 0, false
    local loader = {}

    local failureCodeMap = {
        INTERACT_ADAPTER_MISSING = 'INTERACT_ACTION_ADAPTER_MISSING',
        INTERACT_BUNDLE_CONFLICT = 'INTERACT_DUPLICATE_KEY',
        INTERACT_EVALUATOR_UNAVAILABLE = 'INTERACT_EVALUATOR_MISSING',
        INTERACT_PROVIDER_UNAVAILABLE = 'INTERACT_PROVIDER_MISSING',
    }

    local function failureKey(resourceName, path)
        return resourceName .. '\0' .. path
    end

    local function clearFailure(resourceName, path)
        local key = failureKey(resourceName, path)
        if failures[key] ~= nil then
            failures[key], failureCount = nil, math.max(0, failureCount - 1)
        end
    end

    local function clearResourceFailures(resourceName, expected)
        for key, record in pairs(failures) do
            if record.resource == resourceName
                and (expected == nil or expected[record.path] ~= true) then
                failures[key], failureCount = nil, math.max(0, failureCount - 1)
            end
        end
    end

    local function recordFailure(resourceName, path, operationError)
        local key = failureKey(resourceName, path)
        local details = type(operationError) == 'table' and operationError.details or nil
        local sourceCode = type(operationError) == 'table'
            and operationError.code or 'INTERACT_BUNDLE_INVALID'
        local code = type(details) == 'table' and details.diagnosticCode
            or failureCodeMap[sourceCode] or 'INTERACT_BUNDLE_REJECTED'
        if not Validation.errorCode(code) then code = 'INTERACT_BUNDLE_REJECTED' end
        if failures[key] == nil then
            if failureCount >= Limits.maximumBundles then
                failureOverflow = true
                return false
            end
            failureCount = failureCount + 1
        end
        failures[key] = { resource = resourceName, path = path,
            code = code, sourceCode = tostring(sourceCode):sub(1, 64) }
        return true
    end

    local function validPath(path)
        if type(path) ~= 'string' or #path < 28 or #path > 240
            or path:match('^interactions/[A-Za-z0-9._/-]+%.interact%.json$') == nil
            or path:find('\\', 1, true) or path:find('//', 1, true) then return false end
        for segment in path:gmatch('[^/]+') do
            if segment == '.' or segment == '..' then return false end
        end
        return true
    end

    local function recordFor(resourceName)
        local snapshot, snapshotError = getRuntimeSnapshot()
        if not snapshot then return nil, snapshotError end
        for _, record in ipairs(snapshot.resources or {}) do
            if record.name == resourceName then return record end
        end
        return Validation.failure('INTERACT_OWNER_STOPPED',
            'Interaction bundle owner is not registered in Core.', true)
    end

    local function declared(record, path)
        for _, candidate in ipairs(record.manifest and record.manifest.interactionBundles or {}) do
            if candidate == path then return true end
        end
        return false
    end

    function loader.load(resourceName, path, replace, expectedEpoch, context)
        if not validPath(path) then return Validation.failure('INTERACT_BUNDLE_INVALID',
            'Interaction bundle path is invalid.') end
        local record, recordError = recordFor(resourceName)
        if not record then return nil, recordError end
        if record.state ~= 'STARTED' or getResourceState(resourceName) ~= 'started'
            or expectedEpoch ~= nil and record.epoch ~= expectedEpoch then
            return Validation.failure('INTERACT_OWNER_STALE',
                'Interaction bundle owner incarnation is stale.', true)
        end
        if not declared(record, path) then return Validation.failure('INTERACT_BUNDLE_INVALID',
            'Interaction bundle path is not declared by its owner.') end
        if resourceName ~= selfResource then
            local allowed, capabilityError = checkCapability(resourceName,
                'synex.interact.bundle.register', 'interaction bundle activation')
            if not allowed then return nil, capabilityError end
        end
        local encoded = loadResourceFile(resourceName, path)
        if type(encoded) ~= 'string' or #encoded < 2 or #encoded > Limits.maximumPayloadBytes * 8 then
            return Validation.failure('INTERACT_BUNDLE_INVALID',
                'Interaction bundle file is missing or oversized.')
        end
        local decoded, candidate = pcall(decode, encoded)
        if not decoded or not Validation.isPlainTable(candidate) then
            return Validation.failure('INTERACT_BUNDLE_INVALID',
                'Interaction bundle JSON is invalid.')
        end
        local tracked = paths[resourceName] and paths[resourceName][path]
        local result, operationError
        if replace or tracked then
            if not tracked then return Validation.failure('INTERACT_BUNDLE_NOT_FOUND',
                'Interaction bundle path is not active.') end
            result, operationError = registry.replace(resourceName, record.epoch,
                candidate, tracked.revision)
        else result, operationError = registry.register(resourceName, record.epoch, candidate) end
        if not result then
            observability.increment('bundle_validation_failure_total', { outcome = 'rejected' }, 1)
            return nil, operationError
        end
        clearFailure(resourceName, path)
        paths[resourceName] = paths[resourceName] or {}
        paths[resourceName][path] = { key = result.key, revision = result.revision,
            ownerEpoch = record.epoch }
        observability.audit('interact.bundle_activated', 'interaction_bundle', result.key,
            { revision = result.revision, ownerResource = resourceName }, context)
        return result, nil
    end

    function loader.discoverResource(resourceName, context)
        local record, recordError = recordFor(resourceName)
        if not record then return nil, recordError end
        local declaredPaths = record.manifest and record.manifest.interactionBundles or {}
        local expected, report = {}, { resource = resourceName, loaded = 0, failures = {} }
        for _, path in ipairs(declaredPaths) do expected[path] = true end
        clearResourceFailures(resourceName, expected)
        for path, tracked in pairs(paths[resourceName] or {}) do
            if not expected[path] then
                local removed, removeError = registry.unregister(resourceName,
                    record.epoch, tracked.key, tracked.revision)
                if not removed then report.failures[#report.failures + 1] = {
                    path = path, code = removeError.code }
                else paths[resourceName][path] = nil; clearFailure(resourceName, path) end
            end
        end
        for _, path in ipairs(declaredPaths) do
            local tracked = paths[resourceName] and paths[resourceName][path]
            local result, loadError = loader.load(resourceName, path,
                tracked ~= nil, record.epoch, context)
            if result then report.loaded = report.loaded + 1
            else report.failures[#report.failures + 1] = { path = path,
                code = loadError.code }; recordFailure(resourceName, path, loadError) end
        end
        return report, nil
    end

    function loader.discoverAll(context)
        failureOverflow = false
        local snapshot, snapshotError = getRuntimeSnapshot()
        if not snapshot then return nil, snapshotError end
        local resources = {}
        for _, record in ipairs(snapshot.resources or {}) do
            if record.state == 'STARTED' and type(record.manifest) == 'table'
                and type(record.manifest.interactionBundles) == 'table'
                and #record.manifest.interactionBundles > 0 then
                resources[#resources + 1] = record.name
            end
        end
        table.sort(resources)
        local reports, unresolved = {}, {}
        for _, resourceName in ipairs(resources) do
            local report, operationError = loader.discoverResource(resourceName, context)
            if report then
                reports[#reports + 1] = report
                if #report.failures > 0 then unresolved[#unresolved + 1] = resourceName end
            else unresolved[#unresolved + 1] = resourceName;
                recordFailure(resourceName, '<manifest>', operationError)
                observability.denied('bundle.discover', operationError) end
        end
        return { resources = reports, unresolved = unresolved }, nil
    end

    function loader.ownerStopped(resourceName, epoch, context)
        local removed = registry.cleanupOwner(resourceName, epoch)
        paths[resourceName] = nil
        clearResourceFailures(resourceName)
        if removed > 0 then observability.audit('interact.bundle_owner_stopped',
            'resource', resourceName, { removed = removed }, context) end
        return { removed = removed }, nil
    end

    function loader.pathForBundle(resourceName, bundleKey)
        for path, tracked in pairs(paths[resourceName] or {}) do
            if tracked.key == bundleKey then return path end
        end
        return nil
    end
    function loader.failures(limit)
        local maximum = Validation.isInteger(limit, 1, Limits.maximumDoctorFindings)
            and limit or math.min(100, Limits.maximumDoctorFindings)
        local keys = {}
        for key in pairs(failures) do keys[#keys + 1] = key end
        table.sort(keys)
        local items = {}
        for index = 1, math.min(#keys, maximum) do
            items[#items + 1] = Validation.copy(failures[keys[index]])
        end
        return { items = items, total = failureCount,
            hasMore = failureCount > #items or failureOverflow,
            truncated = failureCount > #items or failureOverflow }, nil
    end
    return loader
end
