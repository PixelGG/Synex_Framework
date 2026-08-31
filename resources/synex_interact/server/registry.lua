SynexInteractRegistry = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractRegistry.create(options)
    local compiler = assert(options.compiler, 'interact registry requires compiler')
    local isOwnerCurrent = assert(options.isOwnerCurrent,
        'interact registry requires owner fencing')
    local onChanged = options.onChanged or function() end
    local bundles, bundleOrder, objectIndex, intentIndex, graphIndex = {}, {}, {}, {}, {}
    local providers, evaluators, adapters = {}, {}, {}
    local revision, discoveryCache = 1, nil
    local registry = {}

    local function fallbackJsonEncode(value)
        local active = {}
        local function encode(candidate)
            local kind = type(candidate)
            if kind == 'nil' then return 'null' end
            if kind == 'boolean' then return candidate and 'true' or 'false' end
            if kind == 'number' then
                return Validation.isFinite(candidate) and tostring(candidate) or nil
            end
            if kind == 'string' then
                local fragments = { '"' }
                for index = 1, #candidate do
                    local byte = candidate:byte(index)
                    if byte == 34 then fragments[#fragments + 1] = '\\"'
                    elseif byte == 92 then fragments[#fragments + 1] = '\\\\'
                    elseif byte == 8 then fragments[#fragments + 1] = '\\b'
                    elseif byte == 9 then fragments[#fragments + 1] = '\\t'
                    elseif byte == 10 then fragments[#fragments + 1] = '\\n'
                    elseif byte == 12 then fragments[#fragments + 1] = '\\f'
                    elseif byte == 13 then fragments[#fragments + 1] = '\\r'
                    elseif byte < 32 then
                        fragments[#fragments + 1] = ('\\u%04x'):format(byte)
                    else fragments[#fragments + 1] = candidate:sub(index, index) end
                end
                fragments[#fragments + 1] = '"'
                return table.concat(fragments)
            end
            if not Validation.isPlainTable(candidate) or active[candidate] then return nil end
            active[candidate] = true
            local length, numeric, strings = #candidate, 0, 0
            for key in pairs(candidate) do
                if Validation.isInteger(key, 1, length) then numeric = numeric + 1
                elseif type(key) == 'string' then strings = strings + 1
                else active[candidate] = nil; return nil end
            end
            local fragments = {}
            if strings == 0 and numeric == length then
                fragments[1] = '['
                for index = 1, length do
                    local child = encode(candidate[index])
                    if not child then active[candidate] = nil; return nil end
                    if index > 1 then fragments[#fragments + 1] = ',' end
                    fragments[#fragments + 1] = child
                end
                fragments[#fragments + 1] = ']'
            elseif numeric == 0 then
                local keys = {}
                for key in pairs(candidate) do keys[#keys + 1] = key end
                table.sort(keys)
                fragments[1] = '{'
                for index, key in ipairs(keys) do
                    local encodedKey, child = encode(key), encode(candidate[key])
                    if not encodedKey or not child then active[candidate] = nil; return nil end
                    if index > 1 then fragments[#fragments + 1] = ',' end
                    fragments[#fragments + 1] = encodedKey
                    fragments[#fragments + 1] = ':'
                    fragments[#fragments + 1] = child
                end
                fragments[#fragments + 1] = '}'
            else active[candidate] = nil; return nil end
            active[candidate] = nil
            return table.concat(fragments)
        end
        return encode(value)
    end

    local function encodeJson(value)
        local codec = type(json) == 'table' and json.encode or nil
        if Validation.isCallable(codec) then
            local ok, encoded = pcall(codec, value)
            if ok and type(encoded) == 'string' then return encoded end
            return nil
        end
        return fallbackJsonEncode(value)
    end

    local function encodedSize(value)
        local encoded = encodeJson(value)
        return encoded and #encoded or nil
    end

    local function pageEnvelope(payload)
        return {
            schemaVersion = 1, revision = Limits.maximumSafeInteger,
            unchanged = false, page = Limits.maximumDiscoveryPages,
            pageCount = Limits.maximumDiscoveryPages, complete = false,
            objectCount = Limits.maximumDiscoveryObjects,
            totalBytes = Limits.maximumDiscoveryPayloadBytes,
            payload = payload,
        }
    end

    local function discoveryFailure(message)
        local _, operationError = Validation.failure('INTERACT_PAYLOAD_TOO_LARGE', message)
        discoveryCache = { revision = revision, operationError = operationError }
        return nil, operationError
    end

    local function discoveryPages()
        if discoveryCache and discoveryCache.revision == revision then
            return discoveryCache.pages, discoveryCache.operationError
        end
        local objects, totalBytes = {}, 2
        for _, bundleKey in ipairs(bundleOrder) do
            local bundle = bundles[bundleKey]
            for _, object in ipairs(bundle.discovery) do
                if #objects >= Limits.maximumDiscoveryObjects then
                    return discoveryFailure(
                        'The interaction discovery manifest exceeds its object bound.')
                end
                local objectBytes = encodedSize(object)
                if not objectBytes then
                    return discoveryFailure(
                        'The interaction discovery manifest cannot be encoded safely.')
                end
                totalBytes = totalBytes + objectBytes + (#objects > 0 and 1 or 0)
                if totalBytes > Limits.maximumDiscoveryPayloadBytes then
                    return discoveryFailure(
                        'The interaction discovery manifest exceeds its aggregate byte bound.')
                end
                objects[#objects + 1] = object
            end
        end

        local payload = encodeJson(objects)
        if not payload or #payload > Limits.maximumDiscoveryPayloadBytes then
            return discoveryFailure(
                'The interaction discovery manifest cannot be encoded safely.')
        end
        local pages, offset = {}, 1
        while offset <= #payload do
            if #pages >= Limits.maximumDiscoveryPages then
                return discoveryFailure(
                    'The interaction discovery manifest cannot fit bounded transport pages.')
            end
            local finish = math.min(#payload,
                offset + Limits.maximumDiscoveryChunkBytes - 1)
            while finish < #payload do
                local nextByte = payload:byte(finish + 1)
                if not nextByte or nextByte < 128 or nextByte > 191 then break end
                finish = finish - 1
            end
            if finish < offset then
                return discoveryFailure(
                    'The interaction discovery manifest contains an invalid chunk boundary.')
            end
            local chunk = payload:sub(offset, finish)
            local responseBytes = encodedSize(pageEnvelope(chunk))
            if not responseBytes
                or responseBytes > Limits.maximumDiscoveryPageBytes then
                return discoveryFailure(
                    'An interaction discovery chunk exceeds the transport page bound.')
            end
            pages[#pages + 1] = chunk
            offset = finish + 1
        end
        discoveryCache = { revision = revision, pages = pages,
            objectCount = #objects, totalBytes = #payload }
        return pages, nil
    end

    local function ownerValid(owner, epoch)
        if not Validation.resourceName(owner) or not Validation.isInteger(epoch, 1)
            or not isOwnerCurrent(owner, epoch) then
            return Validation.failure('INTERACT_OWNER_STALE',
                'The interaction owner incarnation is stale.')
        end
        return true
    end

    local function removeIndexes(bundle)
        for _, key in ipairs(bundle.objectOrder) do
            if objectIndex[key] and objectIndex[key].bundle == bundle then objectIndex[key] = nil end
        end
        for _, key in ipairs(bundle.intentOrder) do
            if intentIndex[key] and intentIndex[key].bundle == bundle then intentIndex[key] = nil end
        end
        for _, key in ipairs(bundle.graphOrder) do
            if graphIndex[key] and graphIndex[key].bundle == bundle then graphIndex[key] = nil end
        end
    end

    local function conflicts(compiled, replacing)
        for _, key in ipairs(compiled.objectOrder) do
            local current = objectIndex[key]
            if current and current.bundle ~= replacing then return 'smartObject', key end
        end
        for _, key in ipairs(compiled.intentOrder) do
            local current = intentIndex[key]
            if current and current.bundle ~= replacing then return 'intent', key end
        end
        for _, key in ipairs(compiled.graphOrder) do
            local current = graphIndex[key]
            if current and current.bundle ~= replacing then return 'graph', key end
        end
    end

    local function applyIndexes(compiled)
        for _, key in ipairs(compiled.objectOrder) do
            objectIndex[key] = { bundle = compiled, value = compiled.objects[key] }
        end
        for _, key in ipairs(compiled.intentOrder) do
            intentIndex[key] = { bundle = compiled, value = compiled.intents[key] }
        end
        for _, key in ipairs(compiled.graphOrder) do
            graphIndex[key] = { bundle = compiled, value = compiled.graphs[key] }
        end
    end

    local function adaptersAvailable(compiled)
        local function evaluatorAvailable(reference, details)
            if reference == nil then return true end
            local evaluator = evaluators[reference]
            if not evaluator or evaluator.owner ~= compiled.ownerResource
                or evaluator.epoch ~= compiled.ownerEpoch then
                return Validation.failure('INTERACT_EVALUATOR_UNAVAILABLE',
                    'An interaction evaluator is not registered by its owner.',
                    false, details)
            end
            return true
        end
        for _, objectKey in ipairs(compiled.objectOrder) do
            local object = compiled.objects[objectKey]
            local binding = object.binding
            if binding.type == 'dynamic' then
                local provider = providers[binding.provider]
                if not provider or provider.owner ~= compiled.ownerResource
                    or provider.epoch ~= compiled.ownerEpoch then
                    return Validation.failure('INTERACT_PROVIDER_UNAVAILABLE',
                        'A dynamic Smart Object provider is not registered by its owner.',
                        false, { smartObject = objectKey, provider = binding.provider })
                end
            end
            local available, availabilityError = evaluatorAvailable(
                object.availabilityPolicy.evaluator,
                { smartObject = objectKey,
                    evaluator = object.availabilityPolicy.evaluator })
            if not available then return nil, availabilityError end
            for _, slotKey in ipairs(object.slotOrder) do
                local policy = object.slots[slotKey].availabilityPolicy
                available, availabilityError = evaluatorAvailable(policy.evaluator, {
                    smartObject = objectKey, slot = slotKey,
                    evaluator = policy.evaluator,
                })
                if not available then return nil, availabilityError end
            end
        end
        for _, graphKey in ipairs(compiled.graphOrder) do
            local graph = compiled.graphs[graphKey]
            for _, nodeKey in ipairs(graph.nodeOrder) do
                local node = graph.nodes[nodeKey]
                if node.adapter ~= nil then
                    local adapter = adapters[node.adapter]
                    if not adapter or adapter.owner ~= compiled.ownerResource
                        or adapter.epoch ~= compiled.ownerEpoch then
                        return Validation.failure('INTERACT_ADAPTER_MISSING',
                            'An Action Graph typed adapter is not registered by its owner.',
                            false, { graph = graphKey, node = nodeKey, adapter = node.adapter })
                    end
                end
                if node.condition and node.condition.kind == 'evaluator' then
                    local available, availabilityError = evaluatorAvailable(
                        node.condition.evaluator, { graph = graphKey, node = nodeKey,
                            evaluator = node.condition.evaluator })
                    if not available then return nil, availabilityError end
                end
            end
        end
        return true
    end

    local function activate(compiled, replacing)
        local kind, key = conflicts(compiled, replacing)
        if kind then return Validation.failure('INTERACT_BUNDLE_CONFLICT',
            'Interaction definition ownership conflicts with an active bundle.', false,
            { kind = kind, key = key }) end
        if replacing then removeIndexes(replacing) end
        bundles[compiled.key] = compiled
        if not replacing then
            bundleOrder[#bundleOrder + 1] = compiled.key
            table.sort(bundleOrder)
        end
        applyIndexes(compiled)
        revision = revision + 1
        discoveryCache = nil
        onChanged(revision, compiled.key, compiled.ownerResource,
            compiled.ownerEpoch, replacing and 'replaced' or 'registered')
        return {
            key = compiled.key, revision = compiled.revision,
            ownerResource = compiled.ownerResource, ownerEpoch = compiled.ownerEpoch,
            activated = true,
        }, nil
    end

    function registry.register(owner, epoch, bundle)
        local valid, ownerError = ownerValid(owner, epoch)
        if not valid then return nil, ownerError end
        if bundles[bundle and bundle.key] then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'The interaction bundle key is already active.')
        end
        local count, owned = #bundleOrder, 0
        for _, key in ipairs(bundleOrder) do
            if bundles[key].ownerResource == owner then owned = owned + 1 end
        end
        if count >= Limits.maximumBundles or owned >= Limits.maximumOwnerBundles then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'The bounded interaction bundle capacity is exhausted.')
        end
        local compiled, compileError = compiler.compile(bundle, owner, epoch)
        if not compiled then return nil, compileError end
        return activate(compiled, nil)
    end

    function registry.replace(owner, epoch, bundle, expectedRevision)
        local valid, ownerError = ownerValid(owner, epoch)
        if not valid then return nil, ownerError end
        local current = bundles[bundle and bundle.key]
        if not current then return Validation.failure('INTERACT_BUNDLE_NOT_FOUND',
            'The interaction bundle is not active.') end
        if current.ownerResource ~= owner or current.ownerEpoch ~= epoch then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'A resource cannot replace another owner interaction bundle.')
        end
        if current.revision ~= expectedRevision or bundle.revision <= current.revision then
            return Validation.failure('INTERACT_BUNDLE_STALE',
                'The interaction bundle revision is stale.')
        end
        local compiled, compileError = compiler.compile(bundle, owner, epoch)
        if not compiled then return nil, compileError end
        return activate(compiled, current)
    end

    function registry.unregister(owner, epoch, key, expectedRevision)
        local valid, ownerError = ownerValid(owner, epoch)
        if not valid then return nil, ownerError end
        local current = bundles[key]
        if not current then return Validation.failure('INTERACT_BUNDLE_NOT_FOUND',
            'The interaction bundle is not active.') end
        if current.ownerResource ~= owner or current.ownerEpoch ~= epoch then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'A resource cannot remove another owner interaction bundle.')
        end
        if current.revision ~= expectedRevision then
            return Validation.failure('INTERACT_BUNDLE_STALE',
                'The interaction bundle revision is stale.')
        end
        removeIndexes(current)
        bundles[key] = nil
        for index, candidate in ipairs(bundleOrder) do
            if candidate == key then table.remove(bundleOrder, index); break end
        end
        revision = revision + 1
        discoveryCache = nil
        onChanged(revision, key, current.ownerResource, current.ownerEpoch, 'unregistered')
        return { key = key, removed = true }, nil
    end

    function registry.cleanupOwner(owner, epoch)
        local removed = {}
        for _, key in ipairs(bundleOrder) do
            local bundle = bundles[key]
            if bundle and bundle.ownerResource == owner
                and (epoch == nil or bundle.ownerEpoch == epoch) then removed[#removed + 1] = key end
        end
        for _, key in ipairs(removed) do
            local bundle = bundles[key]
            removeIndexes(bundle)
            bundles[key] = nil
            for index, candidate in ipairs(bundleOrder) do
                if candidate == key then table.remove(bundleOrder, index); break end
            end
        end
        for key, item in pairs(providers) do
            if item.owner == owner and (epoch == nil or item.epoch == epoch) then providers[key] = nil end
        end
        for key, item in pairs(evaluators) do
            if item.owner == owner and (epoch == nil or item.epoch == epoch) then evaluators[key] = nil end
        end
        for key, item in pairs(adapters) do
            if item.owner == owner and (epoch == nil or item.epoch == epoch) then adapters[key] = nil end
        end
        if #removed > 0 then
            revision = revision + 1
            discoveryCache = nil
            onChanged(revision, owner, owner, epoch, 'owner_stopped')
        end
        return #removed
    end

    local function registerExtension(collection, maximum, owner, epoch, definition, handler,
        kind, maximumTimeoutMs, defaultTimeoutMs)
        local valid, ownerError = ownerValid(owner, epoch)
        if not valid then return nil, ownerError end
        if not Validation.exactObject(definition, { 'key' }, { 'priority', 'timeoutMs' })
            or not Validation.identifier(definition.key)
            or definition.priority ~= nil and (not Validation.isFinite(definition.priority)
                or definition.priority < -100 or definition.priority > 100)
            or definition.timeoutMs ~= nil and not Validation.isInteger(
                definition.timeoutMs, 1, maximumTimeoutMs)
            or not Validation.isCallable(handler) then
            return Validation.failure('INTERACT_BUNDLE_INVALID',
                'Interaction extension registration is invalid.')
        end
        if definition.key:sub(1, #owner + 1) ~= owner .. ':' then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'Interaction extension keys must use their owner namespace.')
        end
        local count = 0
        for _ in pairs(collection) do count = count + 1 end
        if count >= maximum or collection[definition.key] then
            return Validation.failure('INTERACT_BUNDLE_CONFLICT',
                'Interaction extension capacity or ownership conflicts.')
        end
        local normalized = Validation.copy(definition)
        normalized.timeoutMs = normalized.timeoutMs or defaultTimeoutMs
        local item = { owner = owner, epoch = epoch, definition = normalized,
            handler = handler, kind = kind }
        collection[definition.key] = item
        return {
            key = definition.key,
            unregister = function()
                local current = collection[definition.key]
                if current ~= item then return false end
                collection[definition.key] = nil
                return true
            end,
        }, nil
    end

    function registry.registerProvider(owner, epoch, definition, handler)
        return registerExtension(providers, Limits.maximumProviders,
            owner, epoch, definition, handler, 'provider', 1000,
            Limits.providerTimeoutMs)
    end
    function registry.registerEvaluator(owner, epoch, definition, handler)
        return registerExtension(evaluators, Limits.maximumEvaluators,
            owner, epoch, definition, handler, 'evaluator', 1000,
            Limits.evaluatorTimeoutMs)
    end
    function registry.registerAdapter(owner, epoch, definition, handler)
        return registerExtension(adapters, Limits.maximumAdapters,
            owner, epoch, definition, handler, 'adapter',
            Limits.graphMaximumTimeoutMs, Limits.graphNodeTimeoutMs)
    end

    function registry.resolveIntent(key, expectedRevision)
        local entry = intentIndex[key]
        if not entry then return Validation.failure('INTERACT_INTENT_NOT_FOUND',
            'The interaction intent is not active.') end
        if expectedRevision ~= nil and entry.bundle.revision ~= expectedRevision then
            return Validation.failure('INTERACT_INTENT_STALE',
                'The interaction intent revision is stale.')
        end
        local objectEntry = objectIndex[entry.value.smartObjectKey]
        local graphEntry = graphIndex[entry.value.actionGraphRef]
        if not objectEntry or not graphEntry then
            return Validation.failure('INTERACT_BUNDLE_INVALID',
                'The interaction intent dependencies are unavailable.')
        end
        return {
            bundle = entry.bundle, intent = entry.value,
            object = objectEntry.value, graph = graphEntry.value,
        }, nil
    end

    function registry.getObject(key)
        local entry = objectIndex[key]
        return entry and entry.value or nil, entry and entry.bundle or nil
    end
    function registry.getGraph(key)
        local entry = graphIndex[key]
        return entry and entry.value or nil, entry and entry.bundle or nil
    end
    function registry.getEvaluator(key) return evaluators[key] end
    function registry.getProvider(key) return providers[key] end
    function registry.getAdapter(key) return adapters[key] end
    function registry.validateRuntimeDependencies(resolved)
        if type(resolved) ~= 'table' or type(resolved.bundle) ~= 'table'
            or type(resolved.object) ~= 'table' or type(resolved.graph) ~= 'table' then
            return Validation.failure('INTERACT_BUNDLE_INVALID',
                'Interaction runtime dependencies cannot be resolved.')
        end
        local probe = {
            ownerResource = resolved.bundle.ownerResource,
            ownerEpoch = resolved.bundle.ownerEpoch,
            objectOrder = { resolved.object.key }, objects = {
                [resolved.object.key] = resolved.object,
            },
            intentOrder = { resolved.intent.key }, intents = {
                [resolved.intent.key] = resolved.intent,
            },
            graphOrder = { resolved.graph.key }, graphs = {
                [resolved.graph.key] = resolved.graph,
            },
        }
        return adaptersAvailable(probe)
    end
    function registry.slotDefinitions()
        local values = {}
        for _, bundleKey in ipairs(bundleOrder) do
            local bundle = bundles[bundleKey]
            for _, objectKey in ipairs(bundle.objectOrder) do
                values[#values + 1] = { bundle = bundle, object = bundle.objects[objectKey] }
            end
        end
        return values
    end
    function registry.providers()
        local result = {}
        for key, item in pairs(providers) do
            result[#result + 1] = { key = key, ownerResource = item.owner,
                ownerEpoch = item.epoch, priority = item.definition.priority or 0 }
        end
        table.sort(result, function(left, right) return left.key < right.key end)
        return result
    end

    function registry.discovery(request)
        if not Validation.exactObject(request,
            { 'knownRevision', 'snapshotRevision', 'page' })
            or not Validation.isInteger(request.knownRevision, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(request.snapshotRevision, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(request.page, 1, Limits.maximumDiscoveryPages) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The interaction discovery page request is invalid.')
        end
        if request.knownRevision == revision then
            if request.snapshotRevision ~= 0 or request.page ~= 1 then
                return Validation.failure('INTERACT_DISCOVERY_STALE',
                    'The interaction discovery transfer is stale.', true)
            end
            return { schemaVersion = 1, revision = revision, unchanged = true,
                page = 1, pageCount = 1, complete = true,
                objectCount = 0, totalBytes = 0, payload = '' }, nil
        end
        if request.page == 1 and request.snapshotRevision ~= 0
            or request.page > 1 and request.snapshotRevision ~= revision then
            return Validation.failure('INTERACT_DISCOVERY_STALE',
                'The interaction discovery revision changed during transfer.', true)
        end
        local pages, pageError = discoveryPages()
        if not pages then return nil, pageError end
        if request.page > #pages then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The interaction discovery page is outside the snapshot bound.')
        end
        return {
            schemaVersion = 1, revision = revision, unchanged = false,
            page = request.page, pageCount = #pages,
            complete = request.page == #pages,
            objectCount = discoveryCache.objectCount,
            totalBytes = discoveryCache.totalBytes,
            payload = pages[request.page],
        }, nil
    end

    function registry.snapshot()
        local objectCount, intentCount, graphCount = 0, 0, 0
        for _ in pairs(objectIndex) do objectCount = objectCount + 1 end
        for _ in pairs(intentIndex) do intentCount = intentCount + 1 end
        for _ in pairs(graphIndex) do graphCount = graphCount + 1 end
        local evaluatorCount, adapterCount = 0, 0
        for _ in pairs(evaluators) do evaluatorCount = evaluatorCount + 1 end
        for _ in pairs(adapters) do adapterCount = adapterCount + 1 end
        return {
            revision = revision, bundles = #bundleOrder,
            smartObjects = objectCount, intents = intentCount, graphs = graphCount,
            providers = #registry.providers(), evaluators = evaluatorCount,
            adapters = adapterCount,
        }
    end

    function registry.list(kind, cursor, limit)
        local values = {}
        if kind == 'bundles' then
            for _, key in ipairs(bundleOrder) do
                local bundle = bundles[key]
                values[#values + 1] = { key = key, revision = bundle.revision,
                    ownerResource = bundle.ownerResource, ownerEpoch = bundle.ownerEpoch,
                    smartObjects = #bundle.objectOrder, intents = #bundle.intentOrder,
                    graphs = #bundle.graphOrder }
            end
        elseif kind == 'smart_objects' then
            for key, entry in pairs(objectIndex) do
                values[#values + 1] = { key = key, revision = entry.bundle.revision,
                    ownerResource = entry.bundle.ownerResource,
                    slots = #entry.value.slotOrder, activities = #entry.value.activities,
                    binding = entry.value.binding.type }
            end
        elseif kind == 'graphs' then
            for key, entry in pairs(graphIndex) do
                values[#values + 1] = { key = key, revision = entry.bundle.revision,
                    ownerResource = entry.bundle.ownerResource,
                    nodes = #entry.value.nodeOrder, entry = entry.value.entry }
            end
        elseif kind == 'providers' then values = registry.providers()
        else return Validation.failure('INTERACT_INVALID_REQUEST',
            'The interaction registry list kind is invalid.') end
        table.sort(values, function(left, right) return left.key < right.key end)
        local start = Validation.isInteger(cursor, 0) and cursor + 1 or 1
        local maximum = Validation.isInteger(limit, 1, 100) and limit or 25
        local items = {}
        for index = start, math.min(#values, start + maximum - 1) do items[#items + 1] = values[index] end
        local nextCursor = start + #items <= #values and start + #items - 1 or nil
        return { items = items, nextCursor = nextCursor,
            hasMore = nextCursor ~= nil, truncated = nextCursor ~= nil }, nil
    end

    function registry.inspect(kind, key)
        local entry = kind == 'smart_object' and objectIndex[key]
            or kind == 'graph' and graphIndex[key] or nil
        if not entry then return Validation.failure('INTERACT_INTENT_NOT_FOUND',
            'The interaction definition was not found.') end
        local value = Validation.copy(entry.value)
        value.ownerResource = entry.bundle.ownerResource
        value.ownerEpoch = entry.bundle.ownerEpoch
        value.revision = entry.bundle.revision
        return value, nil
    end

    function registry.currentRevision() return revision end
    return registry
end
