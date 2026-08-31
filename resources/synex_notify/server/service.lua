SynexNotifyService = {}

local Validation = assert(SynexNotifyValidation, 'notify validation must be loaded first')

function SynexNotifyService.create(options)
    local registry = assert(options.registry, 'notify service requires registry')
    local foundation = assert(options.foundation, 'notify service requires foundation')
    local observability = assert(options.observability,
        'notify service requires observability')
    local resolveOwnerEpoch = options.resolveOwnerEpoch or function(_, callerEpoch)
        return callerEpoch
    end
    local service = {}

    local function contextOwner(context)
        if type(context) ~= 'table' then
            return Validation.failure('NOTIFY_OWNER_INVALID',
                'The notification caller context is unavailable.')
        end
        local owner, ownerError = Validation.resourceName(context.caller)
        if not owner then return nil, ownerError end
        if not Validation.isInteger(context.callerEpoch, 1, 9007199254740991) then
            return Validation.failure('NOTIFY_OWNER_INVALID',
                'The notification caller epoch is invalid.')
        end
        local epoch, epochError = resolveOwnerEpoch(owner, context.callerEpoch)
        if not Validation.isInteger(epoch, 1, 9007199254740991) then
            return nil, type(epochError) == 'table' and epochError or {
                code = 'NOTIFY_OWNER_INVALID',
                message = 'The notification owner incarnation is unavailable.',
                retryable = false,
            }
        end
        return owner, epoch
    end

    local function exactRequest(value, keys)
        if not Validation.exactObject(value, keys) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'The notification service request contains unsupported fields.')
        end
        return value
    end

    local function operationContext(context, operation, origin)
        local result = {
            caller = context.caller,
            callerEpoch = context.callerEpoch,
            traceId = context.traceId,
            operation = operation,
        }
        if origin ~= nil then result.origin = origin end
        return result
    end

    local function send(request, context, origin)
        local candidate, requestError = exactRequest(request, { target = true, payload = true })
        if not candidate or candidate.target == nil or candidate.payload == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A target and notification payload are required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.send(owner, epoch, candidate.target, candidate.payload,
            operationContext(context, origin == 'SYSTEM'
                and 'notify.send_system' or 'notify.send', origin))
    end

    function service.send(request, context)
        return send(request, context, nil)
    end

    function service.sendSystem(request, context)
        return send(request, context, 'SYSTEM')
    end

    local function sendMany(request, context, origin)
        local candidate, requestError = exactRequest(request, { targets = true, payload = true })
        if not candidate or candidate.targets == nil or candidate.payload == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A target list and notification payload are required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.sendMany(owner, epoch, candidate.targets, candidate.payload,
            operationContext(context, origin == 'SYSTEM'
                and 'notify.send_many_system' or 'notify.send_many', origin))
    end

    function service.sendMany(request, context)
        return sendMany(request, context, nil)
    end

    function service.sendManySystem(request, context)
        return sendMany(request, context, 'SYSTEM')
    end

    local function broadcast(request, context, origin)
        local candidate, requestError = exactRequest(request, { payload = true })
        if not candidate or candidate.payload == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A notification payload is required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.broadcast(owner, epoch, candidate.payload,
            operationContext(context, origin == 'SYSTEM'
                and 'notify.broadcast_system' or 'notify.broadcast', origin))
    end

    function service.broadcast(request, context)
        return broadcast(request, context, nil)
    end

    function service.broadcastSystem(request, context)
        return broadcast(request, context, 'SYSTEM')
    end

    function service.update(request, context)
        local candidate, requestError = exactRequest(request, { handle = true, patch = true })
        if not candidate or candidate.handle == nil or candidate.patch == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A notification handle and patch are required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.update(owner, epoch, candidate.handle, candidate.patch,
            operationContext(context, 'notify.update'))
    end

    function service.dismiss(request, context)
        local candidate, requestError = exactRequest(request, { handle = true, reason = true })
        if not candidate or candidate.handle == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A notification handle is required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.dismiss(owner, epoch, candidate.handle, candidate.reason,
            operationContext(context, 'notify.dismiss'))
    end

    function service.cancelProgress(request, context)
        local candidate, requestError = exactRequest(request, {
            handle = true, message = true,
        })
        if not candidate or candidate.handle == nil then
            return nil, requestError or {
                code = 'NOTIFY_INVALID_REQUEST',
                message = 'A progress notification handle is required.', retryable = false,
            }
        end
        local owner, epoch = contextOwner(context)
        if not owner then return nil, epoch end
        return registry.completeProgress(owner, epoch, candidate.handle,
            'CANCELLED', 'neutral', candidate.message,
            operationContext(context, 'notify.cancel_progress'))
    end

    function service.getControlSummary(request)
        if not Validation.exactObject(request or {}, {}) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Notification summary accepts an empty request.')
        end
        local snapshot = registry.snapshot()
        return {
            active = snapshot.active,
            progressActive = snapshot.progressActive,
            actionTokens = snapshot.actionTokens,
            pendingCommands = snapshot.pendingCommands,
            ownerCount = snapshot.ownerCount,
            maximumRecords = snapshot.maximumRecords,
            maximumPendingCommands = snapshot.maximumPendingCommands,
            metrics = snapshot.metrics,
        }, nil
    end

    function service.doctor(request)
        if not Validation.exactObject(request or {}, { limit = true }) then
            return Validation.failure('NOTIFY_INVALID_REQUEST',
                'Notification doctor request is invalid.')
        end
        return registry.doctor(request and request.limit)
    end

    function service.serviceDefinition()
        return {
            name = 'synex.notify',
            version = '1.0.0',
            capabilities = {
                send = 'synex.notify.send',
                send_many = 'synex.notify.send',
                send_system = 'synex.notify.system',
                send_many_system = 'synex.notify.system',
                broadcast = 'synex.notify.broadcast',
                broadcast_system = 'synex.notify.system',
                update = 'synex.notify.update',
                dismiss = 'synex.notify.update',
                cancel_progress = 'synex.notify.update',
                get_control_summary = 'synex.notify.diagnostics.read',
                doctor = 'synex.notify.diagnostics.read',
            },
            methods = {
                send = service.send,
                send_many = service.sendMany,
                send_system = service.sendSystem,
                send_many_system = service.sendManySystem,
                broadcast = service.broadcast,
                broadcast_system = service.broadcastSystem,
                update = service.update,
                dismiss = service.dismiss,
                cancel_progress = service.cancelProgress,
                get_control_summary = service.getControlSummary,
                doctor = service.doctor,
            },
        }
    end

    function service.contractHandler(definition)
        local handlers = {
            ['synex.notify.send'] = service.send,
            ['synex.notify.update'] = service.update,
            ['synex.notify.dismiss'] = service.dismiss,
            ['synex.notify.command.pull'] = registry.pullCommand,
            ['synex.notify.action.invoke'] = registry.invokeAction,
            ['synex.notify.metrics.report'] = observability.reportClient,
        }
        local handler = type(definition) == 'table' and handlers[definition.name] or nil
        if not foundation.isCallable(handler) then
            return nil, {
                code = 'NOTIFY_UNAVAILABLE',
                message = 'A notification contract handler is unavailable.', retryable = false,
            }
        end
        return function(request, context)
            local value, operationError = foundation.protect(handler, request, context)
            if value == nil then return nil, foundation.publicError(operationError) end
            return value, nil
        end
    end

    return service
end
