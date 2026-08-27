local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.bootstrapDiscovery = function(deps)
    local platform = assert(deps.platform, 'bootstrap discovery requires platform')
    local foundation = assert(deps.foundation, 'bootstrap discovery requires foundation')
    local resourceManifest = assert(deps.resourceManifest, 'bootstrap discovery requires resource manifest service')
    local security = assert(deps.security, 'bootstrap discovery requires security')
    local registries = assert(deps.registries, 'bootstrap discovery requires registries')
    local lifecycle = assert(deps.lifecycle, 'bootstrap discovery requires lifecycle')
    local stateService = assert(deps.stateService, 'bootstrap discovery requires state service')
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap discovery requires runtime gate')
    local controlProviders = deps.controlProviders
    local logger = foundation.logger
    local manifests = deps.manifests or {}
    local ownerSnapshotMaximumBytes = deps.ownerSnapshotMaximumBytes or 65536
    local discoveryRevision = 0
    local validatedRevisions = {}
    local ownerRevisions = {}
    local criticalResources = {}

    local function invalidateResource(name)
        local previous = manifests[name]
        if previous and previous.critical == true then criticalResources[name] = true end
        if controlProviders and type(controlProviders.markUnavailable) == 'function' then
            controlProviders:markUnavailable(name)
        end
        manifests[name] = nil
        validatedRevisions[name] = nil
        ownerRevisions[name] = nil
        if type(security.capabilities.unregisterManifest) == 'function' then
            security.capabilities:unregisterManifest(name)
        end
        if type(lifecycle.dependencies.removeConsumer) == 'function' then
            lifecycle.dependencies:removeConsumer(name)
        end
        if type(registries.resources.invalidateManifest) == 'function' then
            registries.resources:invalidateManifest(name)
        end
        return true
    end

    local function resourceManifestPath(name)
        local path = platform.resourceMetadata(name, 'synex_manifest', 0)
        if type(path) ~= 'string' or path == '' then return nil end
        if path:find('..', 1, true) or path:sub(1, 1) == '/' or path:match('^[A-Za-z]:') then return nil end
        return path
    end

    local function validateManifest(name, manifest)
        return resourceManifest:validate(name, manifest)
    end

    local function discoverResource(name)
        invalidateResource(name)
        local path = resourceManifestPath(name)
        if not path then return nil, nil end
        local raw = platform.loadResourceFile(name, path)
        if not raw then return nil, foundation.error('RESOURCE_MANIFEST_MISSING', ('%s declares a missing manifest.'):format(name)) end
        local ok, manifest = pcall(platform.jsonDecode, raw)
        if not ok then return nil, foundation.error('RESOURCE_MANIFEST_INVALID_JSON', ('%s has invalid manifest JSON.'):format(name)) end
        local valid, manifestError = validateManifest(name, manifest)
        if not valid then return nil, manifestError end
        if controlProviders and type(controlProviders.declare) == 'function' then
            local _, declarationError = controlProviders:declare(name, manifest.controlProvider)
            if declarationError then return nil, declarationError end
        end
        security.capabilities:registerManifest(name, manifest)
        for _, requirement in ipairs(manifest.services.require or {}) do
            local service, major = requirement:match('^(.+)@(%d+)$')
            lifecycle.dependencies:require(name, service, '^' .. tostring(major) .. '.0.0', false, manifest.critical)
        end
        for _, requirement in ipairs(manifest.services.optional or {}) do
            local service, major = requirement:match('^(.+)@(%d+)$')
            lifecycle.dependencies:require(name, service, '^' .. tostring(major) .. '.0.0', true, manifest.critical)
        end
        registries.resources:upsert(name, manifest, platform.resourceState(name))
        manifests[name] = manifest
        criticalResources[name] = manifest.critical == true or nil
        discoveryRevision = discoveryRevision + 1
        validatedRevisions[name] = discoveryRevision
        return manifest, nil
    end

    local function discoverAll()
        local names = {}
        for index = 0, platform.numResources() - 1 do
            local name = platform.resourceByIndex(index)
            if name then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local _, err = discoverResource(name)
            if err then
                logger:error('Synex resource discovery failed', {
                    code = foundation.failureCode(err, 'RESOURCE_DISCOVERY_FAILED'),
                    resource = type(name) == 'string' and name or 'unavailable'
                })
                return nil, err
            end
        end
        return true, nil
    end

    local function ensureOwner(name)
        local available, availabilityError = runtimeGate:requireAvailable()
        if not available then return nil, availabilityError end
        local resourceState = platform.resourceState(name)
        if resourceState ~= 'started' and resourceState ~= 'starting' then
            return nil, foundation.error('RESOURCE_UNAVAILABLE',
                'The calling resource is not active.', { retryable = true })
        end
        local manifest = manifests[name]
        local validatedRevision = validatedRevisions[name]
        if not manifest or not validatedRevision then
            local _, err = discoverResource(name)
            if err then return nil, err end
            manifest = manifests[name]
            validatedRevision = validatedRevisions[name]
        end
        if not manifest or not validatedRevision then
            return nil, foundation.error('RESOURCE_NOT_REGISTERED',
                'The calling resource has no currently validated Synex manifest.')
        end
        local epoch = registries.owners:epoch(name)
        if registries.owners:isQuiescing(name, epoch) then
            return nil, foundation.error('OWNER_QUIESCING', 'The calling resource is stopping or restarting.', { retryable = true })
        end
        if registries.owners:isCurrent(name, epoch) then
            if ownerRevisions[name] ~= validatedRevision then
                return nil, foundation.error('STALE_RESOURCE',
                    'The calling resource owner does not match its validated manifest revision.', { retryable = true })
            end
            return epoch, nil
        end
        epoch = registries.owners:activate(name)
        ownerRevisions[name] = validatedRevision
        return epoch, nil
    end

    local function validateResourceDependencies(name, manifest, inactiveResource)
        local findings = {}
        local dependencies = type(manifest.dependencies) == 'table' and manifest.dependencies or {}
        local function inspect(dependency, dependencyClass)
            local state = dependency.name == inactiveResource and 'stopped'
                or platform.resourceState(dependency.name)
            local severity = dependencyClass == 'required' and manifest.critical == true
                and 'error' or 'warning'
            if state ~= 'started' and state ~= 'starting' then
                findings[#findings + 1] = {
                    kind = 'resource-dependency', resource = name, dependency = dependency.name,
                    dependencyClass = dependencyClass, requiredRange = dependency.version,
                    actualVersion = nil, state = tostring(state),
                    code = 'DEPENDENCY_RESOURCE_UNAVAILABLE', severity = severity
                }
                return
            end
            local actualVersion = platform.resourceMetadata(dependency.name, 'version', 0)
            local duplicateVersion = platform.resourceMetadata(dependency.name, 'version', 1)
            local valid, versionError = resourceManifest:validateDependencyVersion(
                dependency, actualVersion, duplicateVersion)
            if not valid then
                findings[#findings + 1] = {
                    kind = 'resource-dependency', resource = name, dependency = dependency.name,
                    dependencyClass = dependencyClass, requiredRange = dependency.version,
                    actualVersion = type(actualVersion) == 'string' and actualVersion or nil,
                    state = tostring(state), code = versionError.code,
                    message = versionError.message, severity = severity
                }
            end
        end
        for _, dependency in ipairs(dependencies.required or {}) do inspect(dependency, 'required') end
        for _, dependency in ipairs(dependencies.optional or {}) do inspect(dependency, 'optional') end
        return findings
    end

    local function validateActive(inactiveResource, includeInactiveCritical)
        local findings = lifecycle.dependencies:validate(inactiveResource)
        local graph = lifecycle.dependencies:snapshot()
        if includeInactiveCritical == true then
            for name in pairs(criticalResources) do
                if manifests[name] == nil then
                    findings[#findings + 1] = {
                        kind = 'resource', resource = name,
                        state = tostring(platform.resourceState(name)),
                        code = 'RESOURCE_MANIFEST_UNAVAILABLE', severity = 'error'
                    }
                end
            end
        end
        for name, manifest in pairs(manifests) do
            local state = name == inactiveResource and 'stopped' or platform.resourceState(name)
            local active = state == 'started' or state == 'starting'
            if not active and includeInactiveCritical == true and manifest.critical == true then
                findings[#findings + 1] = {
                    kind = 'resource', resource = name, state = tostring(state), severity = 'error'
                }
            elseif active then
                for _, dependencyFinding in ipairs(validateResourceDependencies(name, manifest, inactiveResource)) do
                    findings[#findings + 1] = dependencyFinding
                end
                for _, capabilityFinding in ipairs(security.capabilities:preflight(name)) do
                    capabilityFinding.kind = 'capability'
                    capabilityFinding.severity = manifest.critical and 'error' or 'warning'
                    findings[#findings + 1] = capabilityFinding
                end
                for _, provided in ipairs(manifest.services.provide or {}) do
                    local service, major = provided:match('^(.+)@(%d+)$')
                    local version = graph.providers[service] and graph.providers[service][name]
                        and graph.providers[service][name][major] or nil
                    local runtimeHealth = graph.providerHealth and graph.providerHealth[service]
                        and graph.providerHealth[service][name]
                        and graph.providerHealth[service][name][major] or nil
                    if service and (not version or not foundation.semverSatisfies(version,
                        '^' .. tostring(major) .. '.0.0')) then
                        findings[#findings + 1] = {
                            kind = 'provider', resource = name, service = service,
                            severity = manifest.critical and 'error' or 'warning'
                        }
                    elseif runtimeHealth and (runtimeHealth.health == 'UNHEALTHY'
                        or runtimeHealth.circuit == 'OPEN') then
                        findings[#findings + 1] = {
                            kind = 'provider', resource = name, service = service,
                            health = runtimeHealth.health, circuit = runtimeHealth.circuit,
                            severity = manifest.critical and 'error' or 'warning'
                        }
                    end
                end
            end
        end
        table.sort(findings, function(left, right)
            local leftResource = left.resource or left.consumer or ''
            local rightResource = right.resource or right.consumer or ''
            if leftResource == rightResource then
                return tostring(left.service or left.capability or left.dependency or '')
                    < tostring(right.service or right.capability or right.dependency or '')
            end
            return leftResource < rightResource
        end)
        return findings
    end

    local function supportsStateHandoff(name)
        local manifest = manifests[name]
        if not validatedRevisions[name] then return false end
        local snapshot = manifest and manifest.stateSnapshot or nil
        return type(snapshot) == 'table' and snapshot.supported == true and snapshot.schemaVersion == 1
    end

    local function captureStateHandoff(owner, epoch)
        return stateService:captureOwner(owner, epoch, {
            maximumBytes = ownerSnapshotMaximumBytes,
            maximumValues = 512
        })
    end

    local function restoreStateHandoff(owner, epoch, snapshot)
        return stateService:restoreOwner(owner, epoch, snapshot, {
            maximumBytes = ownerSnapshotMaximumBytes,
            maximumValues = 512
        })
    end

    return {
        manifests = manifests,
        invalidateResource = invalidateResource,
        discoverAll = discoverAll,
        discoverResource = discoverResource,
        ensureOwner = ensureOwner,
        validateActive = validateActive,
        supportsStateHandoff = supportsStateHandoff,
        captureStateHandoff = captureStateHandoff,
        restoreStateHandoff = restoreStateHandoff
    }
end
