local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.createBootstrapDiagnosticsShared = function(deps)
    local lifecycle = assert(deps.lifecycle, 'bootstrap diagnostics requires lifecycle')
    local registries = assert(deps.registries, 'bootstrap diagnostics requires registries')
    local messaging = assert(deps.messaging, 'bootstrap diagnostics requires messaging')
    local foundation = assert(deps.foundation, 'bootstrap diagnostics requires foundation')
    local diagnosticsStartedAtMs = foundation.monotonicMs()
    local contractSystem = assert(deps.contractSystem, 'bootstrap diagnostics requires contracts')
    local security = assert(deps.security, 'bootstrap diagnostics requires security')
    local controlProviders = deps.controlProviders

    local function boundedArray(values, maximum)
        local result = {}
        for index = 1, math.min(#values, maximum or 256) do result[index] = foundation.copy(values[index]) end
        return result
    end

    local function resourceDependencyCycles(resources)
        local adjacency, cycles, truncated = {}, {}, false
        for _, resource in ipairs(resources or {}) do
            local dependencies = ((resource.manifest or {}).dependencies or {})
            adjacency[resource.name] = adjacency[resource.name] or {}
            for _, class in ipairs({ 'required', 'optional', 'development' }) do
                for _, dependency in ipairs(dependencies[class] or {}) do
                    if type(dependency) == 'table' and type(dependency.name) == 'string' then
                        adjacency[resource.name][#adjacency[resource.name] + 1] = dependency.name
                    end
                end
            end
            table.sort(adjacency[resource.name])
        end
        local state, stack, positions = {}, {}, {}
        local function visit(node)
            if #cycles >= 16 then truncated = true return end
            state[node] = 'visiting'
            stack[#stack + 1] = node
            positions[node] = #stack
            for _, dependency in ipairs(adjacency[node] or {}) do
                if state[dependency] == 'visiting' then
                    local cycle = {}
                    for index = positions[dependency], #stack do cycle[#cycle + 1] = stack[index] end
                    cycle[#cycle + 1] = dependency
                    cycles[#cycles + 1] = cycle
                elseif state[dependency] ~= 'visited' then
                    visit(dependency)
                end
                if #cycles >= 16 then truncated = true break end
            end
            positions[node] = nil
            stack[#stack] = nil
            state[node] = 'visited'
        end
        local names = {}
        for name in pairs(adjacency) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do if not state[name] then visit(name) end end
        return {
            status = 'AVAILABLE',
            cycleCount = #cycles,
            cycles = cycles,
            truncated = truncated
        }
    end

    local function dependencySnapshot(graph, maximum, resources)
        local entries = {}
        for service, providers in pairs((graph or {}).providers or {}) do
            for resource, versions in pairs(providers) do
                for major, version in pairs(versions) do
                    entries[#entries + 1] = {
                        direction = 'provide', resource = resource, service = service,
                        major = major, version = version
                    }
                end
            end
        end
        for resource, requirements in pairs((graph or {}).consumers or {}) do
            for service, requirement in pairs(requirements) do
                entries[#entries + 1] = {
                    direction = 'require', resource = resource, service = service,
                    range = requirement.range, optional = requirement.optional == true
                }
            end
        end
        for _, resource in ipairs(resources or {}) do
            local dependencies = ((resource.manifest or {}).dependencies or {})
            for _, class in ipairs({ 'required', 'optional', 'development' }) do
                for _, dependency in ipairs(dependencies[class] or {}) do
                    if type(dependency) == 'table' and type(dependency.name) == 'string' then
                        entries[#entries + 1] = {
                            direction = 'resource', resource = resource.name,
                            dependency = dependency.name, dependencyClass = class,
                            range = dependency.version,
                            optional = class ~= 'required'
                        }
                    end
                end
            end
        end
        table.sort(entries, function(a, b)
            if a.resource == b.resource then
                local leftTarget = a.service or a.dependency or ''
                local rightTarget = b.service or b.dependency or ''
                if leftTarget == rightTarget then
                    return table.concat({ a.direction or '', a.dependencyClass or '', a.major or '' }, '|')
                        < table.concat({ b.direction or '', b.dependencyClass or '', b.major or '' }, '|')
                end
                return leftTarget < rightTarget
            end
            return a.resource < b.resource
        end)
        return {
            entries = boundedArray(entries, maximum),
            truncated = #entries > maximum,
            cycleDetection = resourceDependencyCycles(resources)
        }
    end

    local function serviceSnapshot(services, maximum)
        local entries = {}
        for key, providers in pairs(services or {}) do
            for resource, provider in pairs(providers) do
                entries[#entries + 1] = {
                    key = key, resource = resource, version = provider.version,
                    stability = provider.stability, health = provider.health, circuit = provider.circuit
                }
            end
        end
        table.sort(entries, function(a, b)
            if a.key == b.key then return a.resource < b.resource end
            return a.key < b.key
        end)
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function resourceSnapshot(resources, maximum)
        local entries = {}
        for _, resource in ipairs(resources or {}) do
            entries[#entries + 1] = {
                name = resource.name,
                state = resource.state,
                epoch = resource.epoch,
                version = resource.manifest and resource.manifest.version or nil,
                critical = resource.manifest and resource.manifest.critical == true or false,
                health = foundation.copy(resource.health)
            }
        end
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function workerSnapshot(workers, maximum)
        local entries = {}
        for _, worker in ipairs(workers or {}) do
            entries[#entries + 1] = {
                name = worker.name, resource = worker.resource, intervalMs = worker.intervalMs,
                recurring = worker.recurring, health = worker.health, lastRun = worker.lastRun,
                durationMs = worker.durationMs, lastError = worker.lastError, runs = worker.runs
            }
        end
        return { entries = boundedArray(entries, maximum), truncated = #entries > maximum }
    end

    local function selectedMetrics(prefixes, maximum)
        local snapshot = foundation.metrics:snapshot()
        local output = { values = {}, histograms = {}, truncated = false }
        local count = 0
        local function include(key)
            for _, prefix in ipairs(prefixes) do if key:sub(1, #prefix) == prefix then return true end end
            return false
        end
        local keys = {}
        for key in pairs(snapshot.values) do if include(key) then keys[#keys + 1] = { kind = 'values', key = key } end end
        for key in pairs(snapshot.histograms) do if include(key) then keys[#keys + 1] = { kind = 'histograms', key = key } end end
        table.sort(keys, function(a, b) if a.key == b.key then return a.kind < b.kind end return a.key < b.key end)
        for _, item in ipairs(keys) do
            count = count + 1
            if count > (maximum or 128) then output.truncated = true break end
            output[item.kind][item.key] = foundation.copy(snapshot[item.kind][item.key])
        end
        return output
    end

    local function rpcHandlerSnapshot()
        if type(messaging.gateway) ~= 'table'
            or not foundation.isCallable(messaging.gateway.snapshot) then
            return {}, false
        end
        local ok, result = foundation.safeCall(function()
            return messaging.gateway:snapshot()
        end)
        if not ok or type(result) ~= 'table' then return {}, false end
        return result, true
    end

    local function rpcMetricRows(handlers)
        local rows = {}
        for _, handler in ipairs(handlers or {}) do
            rows[#rows + 1] = {
                key = handler.key,
                owner = handler.owner,
                network = handler.network,
                calls = handler.calls,
                callsPerSecond = handler.callsPerSecond,
                failures = handler.failures,
                timeouts = handler.timeouts,
                p50Ms = handler.percentile50DurationMs,
                p95Ms = handler.percentile95DurationMs,
                p99Ms = handler.percentile99DurationMs,
                rateLimit = handler.rateLimit
            }
        end
        return rows
    end

    local function contractEntries()
        local contracts = {}
        for _, contract in ipairs(contractSystem.registry:list()) do
            contracts[#contracts + 1] = {
                name = contract.name,
                version = contract.version,
                provider = contract.provider,
                network = contract.network,
                stability = contract.stability,
                capability = contract.capability
            }
        end
        return contracts
    end

    local function capabilityEntries()
        local capabilities = {}
        for resource, entry in pairs(security.capabilities:snapshot()) do
            local requested = {}
            for capability, enabled in pairs(entry.requested or {}) do
                if enabled then requested[#requested + 1] = capability end
            end
            table.sort(requested)
            local deniedByCapability, deniedCount = {}, 0
            for _, finding in ipairs(security.capabilities:preflight(resource)) do
                if type(finding.capability) == 'string' then
                    deniedByCapability[finding.capability] = finding.reason or 'denied'
                    deniedCount = deniedCount + 1
                end
            end
            local effective = {}
            for _, capability in ipairs(requested) do
                effective[#effective + 1] = {
                    capability = capability,
                    decision = deniedByCapability[capability] and 'DENIED' or 'GRANTED',
                    reason = deniedByCapability[capability]
                }
            end
            local policyAllow = boundedArray((entry.policy and entry.policy.allow) or {}, 128)
            local unusedAllow = {}
            for _, pattern in ipairs(policyAllow) do
                local used = false
                for _, capability in ipairs(requested) do
                    if foundation.wildcardMatch(pattern, capability) then used = true break end
                end
                if not used then unusedAllow[#unusedAllow + 1] = pattern end
            end
            capabilities[#capabilities + 1] = {
                resource = resource,
                requested = boundedArray(requested, 128),
                requestedCount = #requested,
                effective = boundedArray(effective, 128),
                grantedCount = math.max(0, #requested - deniedCount),
                deniedCount = deniedCount,
                allow = policyAllow,
                deny = boundedArray((entry.policy and entry.policy.deny) or {}, 128),
                unusedAllow = boundedArray(unusedAllow, 128),
                unusedAllowTruncated = #unusedAllow > 128
            }
        end
        table.sort(capabilities, function(a, b) return a.resource < b.resource end)
        return capabilities
    end

    local function boundedSortedStrings(values, maximum)
        local output = {}
        for _, value in ipairs(values or {}) do
            if type(value) == 'string' then output[#output + 1] = value end
        end
        table.sort(output)
        return boundedArray(output, maximum or 64), #output > (maximum or 64)
    end

    local function schemaSummary(schema)
        if type(schema) ~= 'table' then
            return { status = 'UNAVAILABLE', reason = 'CONTRACT_SCHEMA_UNAVAILABLE' }
        end
        local properties = {}
        for name in pairs(schema.properties or {}) do
            if type(name) == 'string' then properties[#properties + 1] = name end
        end
        table.sort(properties)
        local required, requiredTruncated = boundedSortedStrings(schema.required, 32)
        return {
            status = 'AVAILABLE',
            type = type(schema.type) == 'string' and schema.type or nil,
            additionalProperties = type(schema.additionalProperties) == 'boolean'
                and schema.additionalProperties or nil,
            properties = boundedArray(properties, 32),
            propertiesTruncated = #properties > 32,
            required = required,
            requiredTruncated = requiredTruncated
        }
    end

    local function resourceManifestSummary(manifest)
        manifest = type(manifest) == 'table' and manifest or {}
        local services = type(manifest.services) == 'table' and manifest.services or {}
        local contracts = type(manifest.contracts) == 'table' and manifest.contracts or {}
        local providedServices, providedServicesTruncated = boundedSortedStrings(
            services.provide, 24)
        local requiredServices, requiredServicesTruncated = boundedSortedStrings(
            services.require, 24)
        local optionalServices, optionalServicesTruncated = boundedSortedStrings(
            services.optional, 24)
        local providedContracts, providedContractsTruncated = boundedSortedStrings(
            contracts.provide, 24)
        local consumedContracts, consumedContractsTruncated = boundedSortedStrings(
            contracts.consume, 24)
        local dependencies = type(manifest.dependencies) == 'table'
            and manifest.dependencies or {}
        local function dependencyEntries(kind)
            local output = {}
            for _, dependency in ipairs(dependencies[kind] or {}) do
                if type(dependency) == 'table' and type(dependency.name) == 'string' then
                    output[#output + 1] = {
                        name = dependency.name,
                        version = dependency.version,
                        class = kind
                    }
                end
            end
            table.sort(output, function(left, right) return left.name < right.name end)
            return boundedArray(output, 24), #output > 24
        end
        local requiredDependencies, requiredDependenciesTruncated = dependencyEntries('required')
        local optionalDependencies, optionalDependenciesTruncated = dependencyEntries('optional')
        local developmentDependencies, developmentDependenciesTruncated = dependencyEntries('development')
        local ownership = type(manifest.dataOwnership) == 'table' and manifest.dataOwnership or {}
        local ownedTables, ownedTablesTruncated = boundedSortedStrings(ownership.tables, 48)
        return {
            version = manifest.version,
            critical = manifest.critical == true,
            services = {
                provide = providedServices,
                require = requiredServices,
                optional = optionalServices,
                truncated = providedServicesTruncated or requiredServicesTruncated
                    or optionalServicesTruncated
            },
            contracts = {
                provide = providedContracts,
                consume = consumedContracts,
                truncated = providedContractsTruncated or consumedContractsTruncated
            },
            dependencies = {
                required = requiredDependencies,
                optional = optionalDependencies,
                development = developmentDependencies,
                truncated = requiredDependenciesTruncated or optionalDependenciesTruncated
                    or developmentDependenciesTruncated
            },
            dataOwnership = {
                tables = ownedTables,
                characterDelete = ownership.characterDelete,
                truncated = ownedTablesTruncated
            },
            stateSnapshot = type(manifest.stateSnapshot) == 'table' and {
                supported = manifest.stateSnapshot.supported == true,
                schemaVersion = manifest.stateSnapshot.schemaVersion
            } or { supported = false }
        }
    end

    local function safeSession(session)
        return {
            id = session.id,
            userId = session.userId,
            characterId = session.characterId,
            playerSource = session.source,
            sourceGeneration = session.sourceGeneration,
            state = session.state,
            version = session.version,
            serverInstanceId = session.serverInstanceId,
            persistencePending = session.persistencePending == true,
            replacementClosePending = session.replacementClosePending == true,
            authorityDeadlineAt = session.authorityDeadlineAt,
            connectedAt = session.connectedAt
        }
    end

    local function dependencyImpact(resourceName, includeGraph)
        local graph = lifecycle.dependencies:snapshot() or {}
        local nodes, edges, nodeIndex, edgeIndex = {}, {}, {}, {}
        local counts = {
            requirements = 0,
            provisions = 0,
            affectedConsumers = 0,
            providers = 0,
            resourceRequirements = 0,
            directDependents = 0,
            indirectDependents = 0
        }
        local truncated = false
        local function addNode(id, label, kind)
            if nodeIndex[id] then return true end
            if #nodes >= 32 then truncated = true return false end
            nodeIndex[id] = true
            nodes[#nodes + 1] = { id = id, label = label, type = kind }
            return true
        end
        local function addEdge(from, to, kind)
            if not nodeIndex[from] or not nodeIndex[to] then truncated = true return end
            local key = table.concat({ from, to, kind }, '|')
            if edgeIndex[key] then return end
            if #edges >= 48 then truncated = true return end
            edgeIndex[key] = true
            edges[#edges + 1] = { from = from, to = to, type = kind }
        end
        local resourceId = 'resource:' .. resourceName
        addNode(resourceId, resourceName, 'resource')
        local directRequirements = (graph.consumers or {})[resourceName] or {}
        for service, requirement in pairs(directRequirements) do
            local serviceId = 'service:' .. service
            addNode(serviceId, service, 'service')
            addEdge(resourceId, serviceId,
                requirement.optional == true and 'optional' or 'required')
            counts.requirements = counts.requirements + 1
            for providerName in pairs(((graph.providers or {})[service]) or {}) do
                local providerId = 'resource:' .. providerName
                addNode(providerId, providerName, 'resource')
                addEdge(providerId, serviceId, 'provider')
                counts.providers = counts.providers + 1
            end
        end
        for service, serviceProviders in pairs(graph.providers or {}) do
            local version = serviceProviders[resourceName]
            if version ~= nil then
                local serviceId = 'service:' .. service
                addNode(serviceId, service, 'service')
                addEdge(resourceId, serviceId, 'provider')
                counts.provisions = counts.provisions + 1
                for consumerName, consumerRequirements in pairs(graph.consumers or {}) do
                    local requirement = consumerRequirements[service]
                    if requirement ~= nil then
                        local consumerId = 'resource:' .. consumerName
                        addNode(consumerId, consumerName, 'resource')
                        addEdge(consumerId, serviceId,
                            requirement.optional == true and 'optional' or 'required')
                        counts.affectedConsumers = counts.affectedConsumers + 1
                    end
                end
            end
        end
        local resourceDependencies, reverseDependencies = {}, {}
        for _, resource in ipairs(registries.resources:list()) do
            resourceDependencies[resource.name] = resourceDependencies[resource.name] or {}
            local manifestDependencies = ((resource.manifest or {}).dependencies or {})
            for _, class in ipairs({ 'required', 'optional', 'development' }) do
                for _, dependency in ipairs(manifestDependencies[class] or {}) do
                    if type(dependency) == 'table' and type(dependency.name) == 'string' then
                        resourceDependencies[resource.name][#resourceDependencies[resource.name] + 1] = {
                            name = dependency.name, class = class, range = dependency.version
                        }
                        reverseDependencies[dependency.name] = reverseDependencies[dependency.name] or {}
                        reverseDependencies[dependency.name][#reverseDependencies[dependency.name] + 1] = {
                            name = resource.name, class = class, range = dependency.version
                        }
                    end
                end
            end
        end
        for _, dependency in ipairs(resourceDependencies[resourceName] or {}) do
            local dependencyId = 'resource:' .. dependency.name
            addNode(dependencyId, dependency.name, 'resource')
            addEdge(resourceId, dependencyId, dependency.class)
            counts.resourceRequirements = counts.resourceRequirements + 1
        end
        local affectedResources, visited = {}, { [resourceName] = true }
        local queue = { { name = resourceName, path = { resourceName }, depth = 0 } }
        local criticalPath = { resourceName }
        local cursor = 1
        while cursor <= #queue and #affectedResources < 64 do
            local current = queue[cursor]
            cursor = cursor + 1
            for _, dependent in ipairs(reverseDependencies[current.name] or {}) do
                local dependentId = 'resource:' .. dependent.name
                local currentId = 'resource:' .. current.name
                addNode(dependentId, dependent.name, 'resource')
                addNode(currentId, current.name, 'resource')
                addEdge(dependentId, currentId, dependent.class)
                if not visited[dependent.name] then
                    visited[dependent.name] = true
                    local path = {}
                    for index, name in ipairs(current.path) do path[index] = name end
                    path[#path + 1] = dependent.name
                    affectedResources[#affectedResources + 1] = {
                        resource = dependent.name,
                        distance = current.depth + 1,
                        dependencyClass = dependent.class
                    }
                    if current.depth == 0 then
                        counts.directDependents = counts.directDependents + 1
                    else
                        counts.indirectDependents = counts.indirectDependents + 1
                    end
                    if #path > #criticalPath then criticalPath = path end
                    queue[#queue + 1] = {
                        name = dependent.name, path = path, depth = current.depth + 1
                    }
                end
            end
        end
        if cursor <= #queue then truncated = true end
        table.sort(nodes, function(left, right) return left.id < right.id end)
        table.sort(edges, function(left, right)
            return table.concat({ left.from, left.to, left.type }, '|')
                < table.concat({ right.from, right.to, right.type }, '|')
        end)
        local exposedNodes, exposedEdges = nil, nil
        if includeGraph ~= false then exposedNodes, exposedEdges = nodes, edges end
        return {
            view = 'dependency_impact',
            resource = resourceName,
            counts = counts,
            nodes = exposedNodes,
            edges = exposedEdges,
            affectedResources = affectedResources,
            criticalPath = criticalPath,
            truncated = truncated,
            cycleDetection = resourceDependencyCycles(registries.resources:list())
        }
    end

    local function requestKeysAllowed(request, allowed)
        if type(request) ~= 'table' then return false end
        for key in pairs(request) do
            if type(key) ~= 'string' or not allowed[key] then return false end
        end
        return true
    end

    local function paginated(entries, request, keyFor)
        local limit = request.limit == nil and 25 or request.limit
        local cursor = request.cursor
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 50
            or (cursor ~= nil and (type(cursor) ~= 'string' or #cursor < 1
                or #cursor > 256 or cursor:find('[%z\1-\31\127]'))) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Core list requests require limit 1 through 50 and a bounded cursor.')
        end
        local output, truncated = {}, false
        for _, entry in ipairs(entries) do
            local key = keyFor(entry)
            if cursor == nil or key > cursor then
                if #output >= limit then
                    truncated = true
                    break
                end
                output[#output + 1] = foundation.copy(entry)
            end
        end
        return {
            items = output,
            limit = limit,
            nextCursor = truncated and keyFor(output[#output]) or nil,
            hasMore = truncated,
            truncated = truncated
        }, nil
    end

    local function providerDiscovery()
        if not controlProviders then
            return {
                schemaVersion = 1,
                generatedAt = foundation.utcIso(),
                providers = {},
                truncated = false
            }
        end
        local snapshot, snapshotError = controlProviders:list()
        return snapshot or {
            schemaVersion = 1,
            generatedAt = foundation.utcIso(),
            providers = {},
            truncated = false,
            error = snapshotError and snapshotError.code or 'UNAVAILABLE'
        }
    end

    return {
        boundedArray = boundedArray,
        resourceDependencyCycles = resourceDependencyCycles,
        dependencySnapshot = dependencySnapshot,
        serviceSnapshot = serviceSnapshot,
        resourceSnapshot = resourceSnapshot,
        workerSnapshot = workerSnapshot,
        selectedMetrics = selectedMetrics,
        rpcHandlerSnapshot = rpcHandlerSnapshot,
        rpcMetricRows = rpcMetricRows,
        contractEntries = contractEntries,
        capabilityEntries = capabilityEntries,
        boundedSortedStrings = boundedSortedStrings,
        schemaSummary = schemaSummary,
        resourceManifestSummary = resourceManifestSummary,
        safeSession = safeSession,
        dependencyImpact = dependencyImpact,
        requestKeysAllowed = requestKeysAllowed,
        paginated = paginated,
        providerDiscovery = providerDiscovery,
        diagnosticsStartedAtMs = diagnosticsStartedAtMs
    }
end
