SynexNotifyApplication = {}

local Foundation = assert(SynexNotifyFoundation, 'notify foundation must be loaded first')
local Validation = assert(SynexNotifyValidation, 'notify validation must be loaded first')

function SynexNotifyApplication.create(options)
    local resourceName = assert(options.resourceName, 'notify application requires resource name')
    local coreResource = assert(options.coreResource, 'notify application requires Core resource')
    local bridgeResource = options.bridgeResource or 'synex_bridge'
    local uiResource = options.uiResource or 'synex_ui'
    local coreRange = options.coreRange or '^1.0.0'
    local coreRef = assert(options.coreRef, 'notify application requires Core reference')
    local registry = assert(options.registry, 'notify application requires registry')
    local service = assert(options.service, 'notify application requires service')
    local controlProvider = assert(options.controlProvider,
        'notify application requires control provider')
    local observability = assert(options.observability,
        'notify application requires observability')
    local acquireCore = assert(options.acquireCore, 'notify application requires Core acquisition')
    local loadResourceFile = options.loadResourceFile or LoadResourceFile
    local decode = assert(options.decode, 'notify application requires JSON decoder')
    local wait = options.wait or Wait
    local createThread = options.createThread or CreateThread
    local getResourceState = options.getResourceState or GetResourceState
    local registerBridgeAdapter = assert(options.registerBridgeAdapter,
        'notify application requires Bridge adapter registration')
    local owners, ownerSerial = {}, 0
    local binding, generation, stopping = nil, 0, false
    local workerFailures = {}
    local application = {}

    local function completeCore(api)
        return type(api) == 'table' and Validation.isInteger(api.ownerEpoch, 1, 9007199254740991)
            and type(api.Services) == 'table' and Foundation.isCallable(api.Services.provide)
            and Foundation.isCallable(api.Services.setHealth)
            and type(api.RPC) == 'table' and Foundation.isCallable(api.RPC.registerServer)
            and Foundation.isCallable(api.RPC.registerNetwork)
            and type(api.Scheduler) == 'table' and Foundation.isCallable(api.Scheduler.every)
            and type(api.ControlProviders) == 'table'
            and Foundation.isCallable(api.ControlProviders.register)
            and type(api.Ids) == 'table' and Foundation.isCallable(api.Ids.next)
            and type(api.Players) == 'table' and Foundation.isCallable(api.Players.getBySource)
            and type(api.Capabilities) == 'table'
            and Foundation.isCallable(api.Capabilities.checkResource)
            and type(api.Metrics) == 'table'
            and Foundation.isCallable(api.Metrics.increment)
            and Foundation.isCallable(api.Metrics.gauge)
            and Foundation.isCallable(api.Metrics.observe)
            and type(api.Audit) == 'table'
            and Foundation.isCallable(api.Audit.append)
            and type(api.Events) == 'table' and Foundation.isCallable(api.Events.publish)
    end

    local function current(candidate)
        return not stopping and type(candidate) == 'table' and binding == candidate
            and candidate.generation == generation and coreRef.value == candidate.api
    end

    local function ensureOwner(owner)
        local resource, resourceError = Validation.resourceName(owner)
        if not resource then return nil, resourceError end
        local state = getResourceState(resource)
        if state ~= 'started' and state ~= 'starting' then
            return Validation.failure('NOTIFY_OWNER_STOPPED',
                'The calling notification resource is not active.')
        end
        local record = owners[resource]
        if record and record.state == 'started' then return record.epoch, nil end
        ownerSerial = ownerSerial + 1
        owners[resource] = { epoch = ownerSerial, state = 'started' }
        return ownerSerial, nil
    end

    local function ownerCurrent(owner, epoch)
        local record = owners[owner]
        if not record or record.state ~= 'started' then
            return Validation.failure('NOTIFY_OWNER_STOPPED',
                'The notification owner stopped.')
        end
        if record.epoch ~= epoch then
            return Validation.failure('NOTIFY_OWNER_STALE',
                'The notification owner restarted.')
        end
        return true
    end

    local function plainJsonCopy(value)
        local active, visited = {}, 0
        local function copy(candidate, depth)
            local kind = type(candidate)
            if kind == 'nil' or kind == 'boolean' or kind == 'string' then
                return candidate
            end
            if kind == 'number' then
                if candidate ~= candidate or candidate == math.huge
                    or candidate == -math.huge then error('non-finite JSON number', 0) end
                return candidate
            end
            if kind ~= 'table' or depth > 24 or active[candidate] then
                error('unsupported JSON container', 0)
            end
            local metadata = getmetatable(candidate)
            if metadata ~= nil then
                if type(metadata) ~= 'table'
                    or (metadata.__jsontype ~= 'object' and metadata.__jsontype ~= 'array') then
                    error('unsupported JSON metadata', 0)
                end
                for key in next, metadata do
                    if key ~= '__jsontype' then error('decorated JSON metadata', 0) end
                end
            end
            active[candidate] = true
            local result = {}
            for key, child in next, candidate do
                visited = visited + 1
                if visited > 16384 or (type(key) ~= 'string'
                    and (type(key) ~= 'number' or key < 1 or key % 1 ~= 0)) then
                    active[candidate] = nil
                    error('JSON container bound exceeded', 0)
                end
                result[key] = copy(child, depth + 1)
            end
            active[candidate] = nil
            return result
        end
        return copy(value, 1)
    end

    local function loadContracts()
        local raw = loadResourceFile(resourceName, 'contracts/notify.contracts.json')
        if type(raw) ~= 'string' or #raw < 2 or #raw > 262144 then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification contract bundle is unavailable.')
        end
        local decoded, bundle = pcall(decode, raw)
        if not decoded then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification contract bundle is invalid.')
        end
        local copied, plain = pcall(plainJsonCopy, bundle)
        if not copied or type(plain) ~= 'table' or plain.schema ~= 1
            or plain.domain ~= 'synex.notify' or type(plain.contracts) ~= 'table'
            or #plain.contracts ~= 6 then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'The notification contract bundle is invalid.')
        end
        bundle = plain
        return bundle.contracts, nil
    end

    local function registerContracts(candidate)
        if candidate.contractsReady then return true end
        local definitions, definitionError = loadContracts()
        if not definitions then return nil, definitionError end
        for _, definition in ipairs(definitions) do
            local key = definition.name .. '@' .. definition.version
            if not candidate.contractTokens[key] then
                local handler, handlerError = service.contractHandler(definition)
                if not handler then return nil, handlerError end
                local register = definition.network == 'client-to-server'
                    and candidate.api.RPC.registerNetwork
                    or candidate.api.RPC.registerServer
                local token, tokenError = register(definition, handler)
                if not token then return nil, tokenError end
                candidate.contractTokens[key] = token
            end
        end
        candidate.contractsReady = true
        return true
    end

    local function registerCompatibility(candidate)
        if candidate.bridgeToken or getResourceState(bridgeResource) ~= 'started' then return true end
        local token, adapterError = registerBridgeAdapter({
            name = 'synex.notify', version = '1.0.0', provider = 'all',
            domain = 'notifications', status = 'PARTIAL', operations = { 'send' },
        }, {
            send = function(context, payload)
                if type(context) ~= 'table' or type(context.consumer) ~= 'string'
                    or type(payload) ~= 'table' then
                    return Validation.failure('NOTIFY_INVALID_REQUEST',
                        'The compatibility notification request is invalid.')
                end
                local epoch, epochError = ensureOwner(context.consumer)
                if not epoch then return nil, epochError end
                if not Validation.exactObject(payload, { target = true, notification = true })
                    or payload.target == nil or payload.notification == nil then
                    return Validation.failure('NOTIFY_INVALID_REQUEST',
                        'The compatibility adapter requires a target and notification.')
                end
                return registry.send(context.consumer, epoch, payload.target,
                    payload.notification, {
                        operation = 'notify.compatibility.send',
                        traceId = context.traceId,
                    })
            end,
        })
        if token then candidate.bridgeToken = token; return true end
        if type(adapterError) == 'table'
            and (adapterError.code == 'COMPAT_PROVIDER_DISABLED'
                or adapterError.code == 'COMPAT_CONSUMER_DENIED') then
            return true
        end
        return nil, adapterError
    end

    local function scheduleWorkers(candidate)
        if candidate.workerToken then return true end
        local ticks = 0
        local token, scheduleError = candidate.api.Scheduler.every(1000, function()
            if not current(candidate) or not candidate.ready then return end
            local value, workerError = Foundation.protect(registry.expire)
            if not value then
                workerFailures.expiry = true
                candidate.api.Services.setHealth('synex.notify', '1.0.0', 'DEGRADED')
                return nil, workerError
            end
            workerFailures.expiry = nil
            ticks = ticks + 1
            if ticks % 5 == 0 then
                local snapshot = registry.snapshot()
                observability.gauge('active', snapshot.active)
                observability.gauge('pending_commands', snapshot.pendingCommands)
                observability.gauge('progress_active', snapshot.progressActive)
                observability.gauge('action_backlog', snapshot.actionTokens)
                observability.refreshClientGauges()
            end
            if ticks % 30 == 0 then
                local report = registry.doctor(50)
                candidate.api.Services.setHealth('synex.notify', '1.0.0',
                    report.status == 'READY' and 'HEALTHY' or 'DEGRADED')
            end
            return value
        end, { name = 'synex_notify.expiry' })
        if not token then return nil, scheduleError end
        candidate.workerToken = token
        return true
    end

    local function synchronizeHealth(candidate)
        if not current(candidate) then return false end
        local report = registry.doctor(50)
        return candidate.api.Services.setHealth('synex.notify', '1.0.0',
            report.status == 'READY' and 'HEALTHY' or 'DEGRADED')
    end

    local function bind(api, expectedGeneration)
        if stopping or generation ~= expectedGeneration then return false end
        if not completeCore(api) then
            return Validation.failure('NOTIFY_UNAVAILABLE',
                'Synex Core returned an incomplete Notify API.', true)
        end
        local candidate = binding
        if not candidate or candidate.api ~= api
            or candidate.generation ~= expectedGeneration then
            candidate = {
                api = api, generation = expectedGeneration,
                contractTokens = {}, ready = false,
            }
            binding = candidate
        end
        coreRef.value = api
        if candidate.ready then return true end
        if not candidate.serviceToken then
            local token, serviceError = api.Services.provide(service.serviceDefinition())
            if not token then return nil, serviceError end
            candidate.serviceToken = token
        end
        local fenced, fenceError = api.Services.setHealth(
            'synex.notify', '1.0.0', 'UNHEALTHY')
        if not fenced then return nil, fenceError end
        local contractsReady, contractError = registerContracts(candidate)
        if not contractsReady then return nil, contractError end
        if not candidate.providerToken then
            local token, providerError = controlProvider.register(api)
            if not token then return nil, providerError end
            candidate.providerToken = token
        end
        local workersReady, workerError = scheduleWorkers(candidate)
        if not workersReady then return nil, workerError end
        local compatibilityReady, compatibilityError = registerCompatibility(candidate)
        if not compatibilityReady then return nil, compatibilityError end
        candidate.ready = true
        local healthy, healthError = synchronizeHealth(candidate)
        if not healthy then candidate.ready = false; return nil, healthError end
        return true
    end

    local function beginBinding()
        generation = generation + 1
        local expected = generation
        binding, coreRef.value = nil, nil
        createThread(function()
            local attempts = 0
            while not stopping and generation == expected do
                local ok, api, apiError = pcall(acquireCore, coreRange)
                local bound, bindError
                if ok and completeCore(api) then
                    bound, bindError = Foundation.protect(bind, api, expected)
                    if bound then return end
                else
                    bindError = apiError or api
                end
                attempts = attempts + 1
                if type(bindError) == 'table' and bindError.retryable == false then
                    print(('[%s] Notify bootstrap failed: %s'):format(resourceName,
                        tostring(bindError.code or 'NOTIFY_UNAVAILABLE')))
                    return
                end
                wait(attempts < 40 and 250 or 5000)
            end
        end)
    end

    local function handleValue(value)
        if type(value) ~= 'table' then return value end
        return {
            notificationId = value.notificationId,
            ownerResource = value.ownerResource,
            ownerEpoch = value.ownerEpoch,
            revision = value.revision,
        }
    end

    local function createHandle(owner, epoch, descriptor)
        local currentDescriptor = handleValue(descriptor)
        local handle = handleValue(descriptor)
        local function guard()
            return ownerCurrent(owner, epoch)
        end
        local function updateDescriptor(value)
            currentDescriptor = handleValue(value)
            handle.notificationId = currentDescriptor.notificationId
            handle.ownerResource = currentDescriptor.ownerResource
            handle.ownerEpoch = currentDescriptor.ownerEpoch
            handle.revision = currentDescriptor.revision
            return handle
        end
        handle.update = function(first, second)
            local patch = first == handle and second or first
            local valid, guardError = guard()
            if not valid then return nil, guardError end
            local value, updateError = registry.update(owner, epoch,
                currentDescriptor, patch, { operation = 'notify.update' })
            if not value then return nil, updateError end
            return updateDescriptor(value), nil
        end
        local function finish(state, tone, first, second)
            local message = first == handle and second or first
            local value, finishError = registry.completeProgress(owner, epoch,
                currentDescriptor, state, tone, message,
                { operation = 'notify.update' })
            if not value then return nil, finishError end
            return updateDescriptor(value), nil
        end
        handle.success = function(first, second) return finish('SUCCESS', 'success', first, second) end
        handle.fail = function(first, second) return finish('FAILED', 'danger', first, second) end
        handle.cancel = function(first, second) return finish('CANCELLED', 'neutral', first, second) end
        handle.dismiss = function(first, second)
            local reason = first == handle and second or first
            local valid, guardError = guard()
            if not valid then return nil, guardError end
            return registry.dismiss(owner, epoch, currentDescriptor,
                reason, { operation = 'notify.dismiss' })
        end
        handle.onAction = function(first, second, third)
            local actionId, callback
            if first == handle then actionId, callback = second, third else actionId, callback = first, second end
            if callback == nil and Foundation.isCallable(actionId) then callback, actionId = actionId, nil end
            local valid, guardError = guard()
            if not valid then return nil, guardError end
            if not Foundation.isCallable(callback) then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'The notification action callback must be callable.')
            end
            if actionId ~= nil and (type(actionId) ~= 'string' or #actionId > 64) then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'The notification action identifier is invalid.')
            end
            return registry.onAction(currentDescriptor.notificationId, owner, epoch,
                actionId or '*', callback)
        end
        return handle
    end

    local function buildFacade(owner, epoch)
        local api = {
            version = '1.0.0', ownerResource = owner, ownerEpoch = epoch,
            limits = {
                sendMany = SynexNotifyLimits.maximumSendMany or 32,
                actions = SynexNotifyLimits.maximumActions or 2,
                queue = SynexNotifyLimits.maximumQueue or 128,
                visible = SynexNotifyLimits.maximumVisible or 4,
            },
        }
        local function guarded(handler)
            return function(...)
                local valid, guardError = ownerCurrent(owner, epoch)
                if not valid then return false, guardError end
                local value, operationError = handler(...)
                if value == nil then return false, Foundation.publicError(operationError) end
                return value, operationError
            end
        end
        api.send = guarded(function(target, payload)
            local descriptor, sendError = registry.send(owner, epoch, target, payload,
                { operation = 'notify.send' })
            if not descriptor then return nil, sendError end
            return createHandle(owner, epoch, descriptor), nil
        end)
        api.show, api.notify = api.send, api.send
        api.sendSystem = guarded(function(target, payload)
            local descriptor, sendError = registry.send(owner, epoch, target, payload, {
                operation = 'notify.send_system', origin = 'SYSTEM',
            })
            if not descriptor then return nil, sendError end
            return createHandle(owner, epoch, descriptor), nil
        end)
        api.showSystem, api.notifySystem = api.sendSystem, api.sendSystem
        api.progress = guarded(function(target, payload)
            if type(payload) ~= 'table' then
                return Validation.failure('NOTIFY_INVALID_REQUEST',
                    'A progress notification payload is required.')
            end
            local candidate = Foundation.copy(payload)
            candidate.kind = 'progress'
            candidate.progress = candidate.progress or {
                state = 'RUNNING', mode = 'indeterminate',
            }
            local descriptor, sendError = registry.send(owner, epoch, target, candidate,
                { operation = 'notify.send' })
            if not descriptor then return nil, sendError end
            return createHandle(owner, epoch, descriptor), nil
        end)
        api.update = guarded(function(handle, patch)
            local descriptor, updateError = registry.update(owner, epoch,
                handleValue(handle), patch, { operation = 'notify.update' })
            if not descriptor then return nil, updateError end
            return createHandle(owner, epoch, descriptor), nil
        end)
        api.dismiss = guarded(function(handle, reason)
            return registry.dismiss(owner, epoch, handleValue(handle), reason,
                { operation = 'notify.dismiss' })
        end)
        api.sendMany = guarded(function(targets, payload)
            local result, sendError = registry.sendMany(owner, epoch, targets, payload,
                { operation = 'notify.send_many' })
            if not result then return nil, sendError end
            for index, descriptor in ipairs(result.handles) do
                result.handles[index] = createHandle(owner, epoch, descriptor)
            end
            return result
        end)
        api.sendManySystem = guarded(function(targets, payload)
            local result, sendError = registry.sendMany(owner, epoch, targets, payload, {
                operation = 'notify.send_many_system', origin = 'SYSTEM',
            })
            if not result then return nil, sendError end
            for index, descriptor in ipairs(result.handles) do
                result.handles[index] = createHandle(owner, epoch, descriptor)
            end
            return result
        end)
        api.broadcast = guarded(function(payload)
            local result, broadcastError = registry.broadcast(owner, epoch, payload,
                { operation = 'notify.broadcast' })
            if not result then return nil, broadcastError end
            for index, descriptor in ipairs(result.handles) do
                result.handles[index] = createHandle(owner, epoch, descriptor)
            end
            return result, nil
        end)
        api.broadcastSystem = guarded(function(payload)
            local result, broadcastError = registry.broadcast(owner, epoch, payload, {
                operation = 'notify.broadcast_system', origin = 'SYSTEM',
            })
            if not result then return nil, broadcastError end
            for index, descriptor in ipairs(result.handles) do
                result.handles[index] = createHandle(owner, epoch, descriptor)
            end
            return result, nil
        end)
        api.getDiagnostics = guarded(function()
            local core = coreRef.value
            local capabilities = type(core) == 'table' and core.Capabilities or nil
            local checkResource = type(capabilities) == 'table'
                and capabilities.checkResource or nil
            if not Foundation.isCallable(checkResource) then
                return Validation.failure('NOTIFY_UNAVAILABLE',
                    'Synex Core is unavailable.', true)
            end
            local allowed, capabilityError = checkResource(
                owner, 'synex.notify.diagnostics.read', 'notify.diagnostics')
            if not allowed then
                observability.increment('capabilityDenied')
                return nil, capabilityError
            end
            return registry.snapshot(), nil
        end)
        return api
    end

    function application.start()
        stopping = false
        beginBinding()
        return true
    end

    function application.getAPI(versionRange)
        local range = versionRange == nil and '^1.0.0' or tostring(versionRange)
        if range ~= '^1.0.0' and range ~= '1' and range ~= 'v1'
            and range ~= '1.0' and range ~= '1.0.0' then
            return Validation.failure('NOTIFY_PROTOCOL_UNSUPPORTED',
                'The requested Notify API version is unavailable.')
        end
        local invoked, owner = pcall(GetInvokingResource)
        if not invoked or type(owner) ~= 'string' or owner == '' then
            return Validation.failure('NOTIFY_OWNER_INVALID',
                'External Notify API access requires an invoking resource.')
        end
        local epoch, ownerError = ensureOwner(owner)
        if not epoch then return nil, ownerError end
        return buildFacade(owner, epoch), nil
    end

    function application.playerDropped(source)
        observability.playerDropped(source)
        return registry.playerDropped(source)
    end

    function application.resolveOwnerEpoch(owner, callerEpoch)
        if callerEpoch ~= nil
            and not Validation.isInteger(callerEpoch, 1, 9007199254740991) then
            return Validation.failure('NOTIFY_OWNER_INVALID',
                'The Core caller epoch is invalid.')
        end
        return ensureOwner(owner)
    end

    function application.resourceStarted(startedResource)
        if startedResource == resourceName then return end
        if startedResource == coreResource then beginBinding(); return end
        if startedResource == uiResource and binding and binding.ready then
            synchronizeHealth(binding)
        end
        if startedResource == bridgeResource and binding and binding.ready then
            binding.bridgeToken = nil
            createThread(function()
                wait(0)
                if current(binding) then registerCompatibility(binding) end
            end)
        end
        local existing = owners[startedResource]
        if existing and existing.state == 'started' then return end
        local resource = Validation.resourceName(startedResource)
        if resource then
            ownerSerial = ownerSerial + 1
            owners[resource] = { epoch = ownerSerial, state = 'started' }
        end
    end

    function application.resourceStopped(stoppedResource)
        if stoppedResource == resourceName then
            stopping = true
            generation = generation + 1
            for owner in pairs(owners) do registry.cleanupOwner(owner, nil) end
            registry.clearPendingCommands()
            binding, coreRef.value = nil, nil
            return true
        end
        if stoppedResource == coreResource then
            generation = generation + 1
            registry.clearPendingCommands()
            binding, coreRef.value = nil, nil
            return true
        end
        if stoppedResource == uiResource and binding and binding.ready then
            binding.api.Services.setHealth('synex.notify', '1.0.0', 'DEGRADED')
        end
        if stoppedResource == bridgeResource and binding then binding.bridgeToken = nil end
        local record = owners[stoppedResource]
        registry.cleanupOwner(stoppedResource, record and record.epoch or nil)
        if record then record.state = 'stopped' end
        return true
    end

    return application
end
