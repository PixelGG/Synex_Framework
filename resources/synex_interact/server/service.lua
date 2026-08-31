SynexInteractService = {}

local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

function SynexInteractService.create(options)
    options = options or {}
    local foundation = assert(options.foundation, 'interact service requires foundation')
    local registry = assert(options.registry, 'interact service requires registry')
    local entityProjection = assert(options.entityProjection,
        'interact service requires entity projection')
    local authority = assert(options.authority, 'interact service requires authority')
    local graph = assert(options.graph, 'interact service requires graph runtime')
    local observability = assert(options.observability, 'interact service requires observability')
    local diagnostics = options.diagnostics
    local resolveOwnerEpoch = options.resolveOwnerEpoch or function(_, epoch) return epoch end
    local service = {}

    local function owner(context)
        if type(context) ~= 'table' then return Validation.failure('INTERACT_OWNER_STALE',
            'Interaction caller context is unavailable.') end
        if not Validation.resourceName(context.caller) then
            return Validation.failure('INTERACT_OWNER_STALE',
                'Interaction caller resource is invalid.')
        end
        local resource = context.caller
        if not Validation.isInteger(context.callerEpoch, 1) then
            return Validation.failure('INTERACT_OWNER_STALE',
                'Interaction caller incarnation is invalid.')
        end
        local epoch, epochError = resolveOwnerEpoch(resource, context.callerEpoch)
        if not epoch then return nil, epochError end
        return resource, epoch
    end

    function service.registerBundle(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        local value, operationError = registry.register(resource, epoch, request.bundle)
        if value then authority.reconcileSlots() end
        return value, operationError
    end
    function service.replaceBundle(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        authority.revokeOwner(resource, epoch, 'BUNDLE_REPLACED')
        local value, operationError = registry.replace(resource, epoch,
            request.bundle, request.expectedRevision)
        if value then authority.reconcileSlots() end
        return value, operationError
    end
    function service.unregisterBundle(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        authority.revokeOwner(resource, epoch, 'BUNDLE_UNREGISTERED')
        local value, operationError = registry.unregister(resource, epoch,
            request.key, request.revision)
        if value then authority.reconcileSlots() end
        return value, operationError
    end
    function service.discoverySnapshot(request)
        return registry.discovery(request)
    end
    function service.discoveryEntities(request, context)
        return entityProjection.snapshot(request, context)
    end
    function service.requestLease(request, context)
        return authority.requestLease(request, context)
    end
    function service.activateLease(request, context)
        return authority.activateLease(request, context)
    end
    function service.cancelSession(request, context)
        return authority.cancelSession(request, context)
    end
    function service.joinSession(request, context)
        return authority.joinSession(request, context)
    end
    function service.leaveSession(request, context)
        return authority.leaveSession(request, context)
    end
    function service.ackGraph(request, context)
        return graph.ack(request, context)
    end
    function service.reportMetrics(request, context)
        return observability.reportClient(request, context)
    end

    function service.registerProvider(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        return registry.registerProvider(resource, epoch, request.definition, request.handler)
    end
    function service.registerEvaluator(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        return registry.registerEvaluator(resource, epoch, request.definition, request.handler)
    end
    function service.registerAdapter(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        return registry.registerAdapter(resource, epoch, request.definition, request.handler)
    end
    function service.inviteParticipant(request, context)
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        return authority.inviteSession(request, resource, epoch)
    end
    function service.renewLease(request, context)
        if not Validation.exactObject(request or {}, { 'leaseId', 'extensionMs' })
            or not Validation.token(request.leaseId, 8, 96)
            or not Validation.isInteger(request.extensionMs, 100, 10000) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'The owner-bound lease renewal request is invalid.')
        end
        local resource, epoch = owner(context)
        if not resource then return nil, epoch end
        return authority.renewLease(request.leaseId, request.extensionMs,
            nil, resource, epoch)
    end
    function service.summary()
        local result = registry.snapshot()
        local lease = authority.snapshot()
        local runtime = graph.snapshot()
        for key, value in pairs(lease) do result[key] = value end
        result.activeExecutions = runtime.active
        return result, nil
    end
    function service.doctor(request)
        if diagnostics then return diagnostics.doctor(request or {}) end
        return { status = 'READY', findings = {}, truncated = false }, nil
    end
    function service.inspect(request)
        if not Validation.exactObject(request or {}, { 'key' }, { 'kind' })
            or not Validation.identifier(request.key)
            or request.kind ~= nil and request.kind ~= 'object'
                and request.kind ~= 'graph' then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction inspection request is invalid.')
        end
        if request.kind == nil or request.kind == 'object' then
            local object, bundle = registry.getObject(request.key)
            if object then
                local slots = {}
                for _, slotKey in ipairs(object.slotOrder or {}) do
                    local slot = object.slots[slotKey]
                    slots[#slots + 1] = {
                        key = slot.key, capacity = slot.capacity,
                        initialState = slot.initialState,
                    }
                end
                return {
                    kind = 'object', key = object.key,
                    ownerResource = bundle.ownerResource,
                    ownerEpoch = bundle.ownerEpoch,
                    bundleRevision = bundle.revision,
                    bindingType = object.binding.type,
                    tags = Validation.copy(object.tags or {}),
                    slots = slots,
                    activities = Validation.copy(object.activities or {}),
                }, nil
            end
        end
        if request.kind == nil or request.kind == 'graph' then
            local graph, bundle = registry.getGraph(request.key)
            if graph then
                local nodes = {}
                for _, nodeKey in ipairs(graph.nodeOrder or {}) do
                    local node = graph.nodes[nodeKey]
                    nodes[#nodes + 1] = {
                        key = node.key, type = node.type,
                        next = node.next,
                    }
                end
                return {
                    kind = 'graph', key = graph.key,
                    ownerResource = bundle.ownerResource,
                    ownerEpoch = bundle.ownerEpoch,
                    bundleRevision = bundle.revision,
                    entry = graph.entry,
                    timeoutMs = graph.timeoutMs,
                    locks = Validation.copy(graph.locks or {}),
                    nodes = nodes,
                }, nil
            end
        end
        return Validation.failure('INTERACT_TARGET_INVALID',
            'The requested Interaction definition is unavailable.')
    end

    function service.replayTrace(request)
        if not Validation.exactObject(request or {}, { 'traceId' }, { 'limit' })
            or not Validation.token(request.traceId, 8, 64)
            or request.limit ~= nil and not Validation.isInteger(request.limit, 1, 100) then
            return Validation.failure('INTERACT_INVALID_REQUEST',
                'Interaction trace replay request is invalid.')
        end
        return observability.replay(request.traceId, request.limit)
    end

    function service.serviceDefinition()
        return {
            name = 'synex.interact', version = '1.0.0',
            capabilities = {
                register_bundle = 'synex.interact.bundle.register',
                replace_bundle = 'synex.interact.bundle.register',
                unregister_bundle = 'synex.interact.bundle.register',
                register_provider = 'synex.interact.provider.register',
                register_evaluator = 'synex.interact.provider.register',
                register_adapter = 'synex.interact.adapter.register',
                invite_participant = 'synex.interact.runtime.manage',
                renew_lease = 'synex.interact.runtime.manage',
                summary = 'synex.interact.diagnostics.read',
                doctor = 'synex.interact.diagnostics.read',
                inspect = 'synex.interact.diagnostics.read',
                replay_trace = 'synex.interact.diagnostics.read',
            },
            methods = {
                register_bundle = service.registerBundle,
                replace_bundle = service.replaceBundle,
                unregister_bundle = service.unregisterBundle,
                register_provider = service.registerProvider,
                register_evaluator = service.registerEvaluator,
                register_adapter = service.registerAdapter,
                invite_participant = service.inviteParticipant,
                renew_lease = service.renewLease,
                summary = service.summary,
                doctor = service.doctor,
                inspect = service.inspect,
                replay_trace = service.replayTrace,
            },
        }
    end

    function service.contractHandler(definition)
        local handlers = {
            ['synex.interact.bundle.register'] = service.registerBundle,
            ['synex.interact.bundle.replace'] = service.replaceBundle,
            ['synex.interact.bundle.unregister'] = service.unregisterBundle,
            ['synex.interact.discovery.snapshot'] = service.discoverySnapshot,
            ['synex.interact.discovery.entities'] = service.discoveryEntities,
            ['synex.interact.lease.request'] = service.requestLease,
            ['synex.interact.lease.activate'] = service.activateLease,
            ['synex.interact.session.cancel'] = service.cancelSession,
            ['synex.interact.session.join'] = service.joinSession,
            ['synex.interact.session.leave'] = service.leaveSession,
            ['synex.interact.graph.ack'] = service.ackGraph,
            ['synex.interact.metrics.report'] = service.reportMetrics,
        }
        local handler = type(definition) == 'table' and handlers[definition.name] or nil
        if not foundation.isCallable(handler) then return Validation.failure('INTERACT_UNAVAILABLE',
            'Interaction contract handler is unavailable.', true) end
        return function(request, context)
            local value, operationError = foundation.protect(handler, request, context)
            if value == nil then
                observability.denied(definition.name, operationError, context)
                return nil, foundation.publicError(operationError)
            end
            return value, nil
        end, nil
    end
    return service
end
