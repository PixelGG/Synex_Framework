local factories = assert(SynexCoreFactories, 'factories must be loaded first')
factories.bootstrapApi = function(deps)
    local platform = assert(deps.platform, 'bootstrap API requires platform')
    local foundation = assert(deps.foundation, 'bootstrap API requires foundation')
    local registries = assert(deps.registries, 'bootstrap API requires registries')
    local logger = foundation.logger
    local security = assert(deps.security, 'bootstrap API requires security')
    local identity = assert(deps.identity, 'bootstrap API requires identity')
    local contractSystem = assert(deps.contractSystem, 'bootstrap API requires contracts')
    local messaging = assert(deps.messaging, 'bootstrap API requires messaging')
    local coreResource = assert(deps.coreResource, 'bootstrap API requires core resource')
    local runtime = assert(deps.runtime, 'bootstrap API requires runtime')
    local stateService = assert(deps.stateService, 'bootstrap API requires state service')
    local lifecycle = assert(deps.lifecycle, 'bootstrap API requires lifecycle')
    local reliability = assert(deps.reliability, 'bootstrap API requires reliability')
    local sagaRuntime = assert(deps.sagaRuntime, 'bootstrap API requires saga runtime')
    local facadeCache = assert(deps.facadeCache, 'bootstrap API requires facade cache')
    local runtimeGate = assert(deps.runtimeGate, 'bootstrap API requires runtime gate')
    local ensureOwner = assert(deps.ensureOwner, 'bootstrap API requires owner discovery')
    local defaultConfig = assert(deps.defaultConfig, 'bootstrap API requires effective configuration')
    local controlProviders, dataPort, domainDeletion = deps.controlProviders, deps.dataPort, deps.domainDeletion
    local validation = assert(factories.bootstrapApiValidation({
        foundation = foundation,
        defaultConfig = defaultConfig,
        reliability = reliability
    }), 'bootstrap API requires validation helpers')
    local mutateAccess, permissionMutationOptions, publicSession, rpcCallOptions = validation.mutateAccess,
        validation.permissionMutationOptions, validation.publicSession, validation.rpcCallOptions
    local function requireCaller()
        local caller = platform.invokingResource()
        if type(caller) ~= 'string' or caller == '' then
            return nil, nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.')
        end
        local epoch, err = ensureOwner(caller)
        if not epoch then return nil, nil, err end
        return caller, epoch, nil
    end
    local function ownerOperation(caller, epoch, operation, handler, traceId, traceContext)
        local available, availabilityError = runtimeGate:requireAvailable()
        if not available then return nil, availabilityError end
        if not registries.owners:isCurrent(caller, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The calling resource restarted.') end
        local invocation = { cancelled = false, reason = nil }
        local token, operationError = registries.owners:beginOperation(caller, epoch, function(reason)
            invocation.cancelled = true
            invocation.reason = tostring(reason or 'owner quiesced')
        end)
        if not token then return nil, operationError end
        local results = table.pack(foundation.safeCall(function()
            local context = traceContext or {}
            context.traceId = traceId
            context.caller = caller
            context.contract = operation
            return foundation.withContext(context, handler, traceId)
        end))
        local ok, value = results[1], results[2]
        registries.owners:finishOperation(caller, epoch, token)
        if invocation.cancelled then
            return nil, foundation.error('REQUEST_ABORTED', 'The operation was aborted while its owner was quiescing.', {
                traceId = traceId,
                retryable = true,
                details = { reason = invocation.reason }
            })
        end
        if not ok then
            logger:error('owner API operation failed', {
                caller = caller,
                operation = operation,
                traceId = traceId,
                code = foundation.failureCode(value, 'OWNER_OPERATION_EXCEPTION')
            })
            return nil, foundation.error('INTERNAL_ERROR', 'The Synex API operation failed.', { traceId = traceId })
        end
        return table.unpack(results, 2, results.n)
    end
    local function guarded(caller, epoch, capability, operation, handler)
        local available, availabilityError = runtimeGate:requireAvailable()
        if not available then return nil, availabilityError end
        if not registries.owners:isCurrent(caller, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The calling resource restarted.') end
        local traceId = foundation.nextId('trace')
        local allowed, err = security.capabilities:check(caller, capability, { traceId = traceId, operation = operation })
        if not allowed then return nil, err end
        return ownerOperation(caller, epoch, operation, handler, traceId)
    end
    local function registerCoreContracts()
        local handlers = {
            ['synex.runtime.status'] = function(_, context)
                local snapshot = lifecycle.core:snapshot()
                if context.version == '1.0.0' then snapshot.playerAdmission = nil end
                return snapshot, nil
            end,
            ['synex.identity.session.by_source'] = function(request)
                local session = publicSession(registries.players:getBySource(request.source))
                return session and { found = true, session = session } or { found = false }, nil
            end,
            ['synex.identity.characters.list'] = function(request)
                local characters, err = identity.characters:list(request.sessionId)
                return characters and { characters = characters } or nil, err
            end,
            ['synex.identity.characters.create'] = function(request)
                return identity.characters:create(request.sessionId, {
                    slot = request.slot, firstName = request.firstName,
                    lastName = request.lastName, dateOfBirth = request.dateOfBirth
                })
            end,
            ['synex.identity.characters.select'] = function(request)
                local result, err = identity.characters:select(request.sessionId, request.characterId)
                if not result then return nil, err end
                return { session = publicSession(result.session), character = result.character }, nil
            end,
            ['synex.identity.characters.delete'] = function(request)
                return identity.characters:delete(request.sessionId, request.characterId)
            end
        }
        local versions = { ['synex.runtime.status'] = { '1.0.0', '2.0.0' } }
        local coreEpoch = registries.owners:epoch(coreResource)
        for name, handler in pairs(handlers) do
            for _, version in ipairs(versions[name] or { '1.0.0' }) do
                local contract, resolveError = contractSystem.registry:resolve(name, version)
                if not contract then return nil, resolveError end
                local _, registerError = messaging.gateway:register(
                    coreResource, coreEpoch, contract, handler)
                if registerError then return nil, registerError end
            end
        end
        return true, nil
    end
    local function registerCoreServices()
        local coreEpoch = registries.owners:epoch(coreResource)
        return messaging.services:provide(coreResource, coreEpoch, {
            name = 'synex.runtime',
            version = SynexProtocol.api,
            capabilities = {
                status = 'synex.runtime.read',
                snapshot = 'synex.runtime.read'
            },
            methods = {
                status = function(request)
                    if next(request) ~= nil then
                        return nil, foundation.error('INVALID_ARGUMENT', 'Runtime status accepts an empty request.')
                    end
                    return lifecycle.core:snapshot(), nil
                end,
                snapshot = function(request)
                    if next(request) ~= nil then
                        return nil, foundation.error('INVALID_ARGUMENT', 'Runtime snapshot accepts an empty request.')
                    end
                    return runtime:snapshot(), nil
                end
            }
        })
    end
    local function buildFacade(caller, epoch)
        local facade = {
            version = SynexProtocol.api,
            owner = caller,
            ownerEpoch = epoch
        }
        facade.Runtime = {
            status = function() return guarded(caller, epoch, 'synex.runtime.read', 'Runtime.status', function() return lifecycle.core:snapshot(), nil end) end,
            version = function() return SynexProtocol.api end,
            health = function() return guarded(caller, epoch, 'synex.runtime.read', 'Runtime.health', function() return lifecycle.core:snapshot(), nil end) end,
            getSnapshot = function()
                return guarded(caller, epoch, 'synex.runtime.read', 'Runtime.getSnapshot', function()
                    return runtime:snapshot(), nil
                end)
            end,
            getRetentionPolicy = function()
                return guarded(caller, epoch, 'synex.runtime.read', 'Runtime.getRetentionPolicy', function()
                    local retention = defaultConfig.retention or {}
                    return foundation.copy({
                        audit = retention.audit,
                        financial = retention.financial,
                        workerIntervalMs = retention.workerIntervalMs,
                        batchSize = retention.batchSize,
                        sessionControlAfterDays = retention.sessionControlAfterDays
                    }), nil
                end)
            end
        }
        local metricPrefix = caller:gsub('[^A-Za-z0-9_]', '_') .. '_'
        local function writeMetric(kind, name, labels, value)
            return guarded(caller, epoch, 'synex.metrics.write',
                'Metrics.' .. kind, function()
                    if type(name) ~= 'string' or name:sub(1, #metricPrefix) ~= metricPrefix then
                        return nil, foundation.error('METRIC_NAMESPACE_FORBIDDEN',
                            'A resource may emit metrics only in its own namespace.')
                    end
                    local writer = foundation.metrics[kind]
                    if type(writer) ~= 'function'
                        or writer(foundation.metrics, name, labels, value) ~= true then
                        return nil, foundation.error('INVALID_METRIC_SAMPLE',
                            'The metric sample is invalid or the bounded series capacity is exhausted.')
                    end
                    return true, nil
                end)
        end
        facade.Metrics = {
            getSnapshot = function()
                return guarded(caller, epoch, 'synex.metrics.read', 'Metrics.getSnapshot', function()
                    return foundation.metrics:snapshot(), nil
                end)
            end,
            increment = function(name, labels, amount)
                return writeMetric('increment', name, labels, amount)
            end,
            gauge = function(name, labels, value)
                return writeMetric('gauge', name, labels, value)
            end,
            observe = function(name, labels, value)
                return writeMetric('observe', name, labels, value)
            end
        }
        facade.Tracing = factories.bootstrapApiTracing({
            platform = platform, foundation = foundation, registries = registries,
            security = security, runtimeGate = runtimeGate, ownerOperation = ownerOperation,
            caller = caller, epoch = epoch, coreResource = coreResource
        })
        facade.Ids = {
            next = function(namespace)
                if type(namespace) ~= 'string' or #namespace < 2 or #namespace > 32
                    or not namespace:match('^[a-z][a-z0-9_]*$') then
                    return nil, foundation.error('INVALID_ARGUMENT', 'ID namespace is invalid.')
                end
                if not registries.owners:isCurrent(caller, epoch) then return nil, foundation.error('STALE_RESOURCE', 'The calling resource restarted.') end
                return foundation.nextId(namespace), nil
            end
        }
        facade.Players = {
            getBySource = function(sourceValue)
                return guarded(caller, epoch, 'synex.identity.read', 'Players.getBySource', function()
                    return publicSession(registries.players:getBySource(tonumber(sourceValue) or sourceValue)), nil
                end)
            end,
            getByUser = function(userId)
                return guarded(caller, epoch, 'synex.identity.read', 'Players.getByUser', function()
                    local result = {}
                    for _, session in ipairs(registries.players:sessionsByUser(userId)) do result[#result + 1] = publicSession(session) end
                    return result, nil
                end)
            end
        }
        facade.Characters = {
            list = function(sessionId) return guarded(caller, epoch, 'synex.identity.read', 'Characters.list', function() return identity.characters:list(sessionId) end) end,
            get = function(characterId) return guarded(caller, epoch, 'synex.identity.read', 'Characters.get', function() return identity.characters:get(characterId) end) end,
            getActive = function(sessionOrSource) return guarded(caller, epoch, 'synex.identity.read', 'Characters.getActive', function() return identity.characters:getActive(sessionOrSource) end) end,
            create = function(sessionId, input) return guarded(caller, epoch, 'synex.characters.create', 'Characters.create', function() return identity.characters:create(sessionId, input) end) end,
            select = function(sessionId, characterId) return guarded(caller, epoch, 'synex.characters.select', 'Characters.select', function() return identity.characters:select(sessionId, characterId) end) end,
            unload = function(sessionId, reason) return guarded(caller, epoch, 'synex.characters.select', 'Characters.unload', function() return identity.characters:unload(sessionId, reason) end) end,
            delete = function(sessionId, characterId) return guarded(caller, epoch, 'synex.characters.delete', 'Characters.delete', function() return identity.characters:delete(sessionId, characterId) end) end,
            registerLifecycleParticipant = function(definition) return identity.characters:registerParticipant(caller, epoch, definition) end
        }
        facade.RPC = {
            call = function(name, version, request, options)
                local prepared, optionsError = rpcCallOptions(options)
                if not prepared then return nil, optionsError end
                return messaging.gateway:invoke(caller, epoch, name, version, request, prepared)
            end,
            registerServer = function(contract, handler)
                if type(contract) ~= 'table' or getmetatable(contract) ~= nil
                    or type(contract.name) ~= 'string'
                    or not security.capabilities:providesContract(caller, contract.name) then
                    return nil, foundation.error('CONTRACT_UNDECLARED', 'The resource manifest does not declare this provided contract.')
                end
                local copied, candidate = foundation.safeCall(foundation.copy, contract)
                if not copied or type(candidate) ~= 'table' then
                    return nil, foundation.error('INVALID_CONTRACT',
                        'The contract definition could not be copied safely.')
                end
                candidate.network = 'none'
                candidate.provider = caller
                return messaging.gateway:register(caller, epoch, candidate, handler)
            end,
            registerNetwork = function(contract, handler)
                if type(contract) ~= 'table' or getmetatable(contract) ~= nil
                    or type(contract.name) ~= 'string'
                    or not security.capabilities:providesContract(caller, contract.name) then
                    return nil, foundation.error('CONTRACT_UNDECLARED', 'The resource manifest does not declare this provided contract.')
                end
                local copied, candidate = foundation.safeCall(foundation.copy, contract)
                if not copied or type(candidate) ~= 'table' then
                    return nil, foundation.error('INVALID_CONTRACT',
                        'The contract definition could not be copied safely.')
                end
                candidate.network = 'client-to-server'
                candidate.provider = caller
                return messaging.gateway:register(caller, epoch, candidate, handler)
            end
        }
        facade.Capabilities = {
            checkResource = function(targetResource, capability, operation)
                return guarded(caller, epoch, 'synex.capabilities.delegate', 'Capabilities.checkResource', function(traceId)
                    if type(targetResource) ~= 'string' or #targetResource < 3 or #targetResource > 64
                        or not targetResource:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
                        or targetResource == coreResource or targetResource == caller then
                        return nil, foundation.error('INVALID_DELEGATION_TARGET', 'Capability delegation target is invalid.', { traceId = traceId })
                    end
                    if type(capability) ~= 'string' or #capability < 1 or #capability > 128
                        or not capability:match('^[a-z][a-z0-9%._%-]*$') then
                        return nil, foundation.error('INVALID_CAPABILITY', 'Delegated capability is invalid.', { traceId = traceId })
                    end
                    if operation ~= nil and (type(operation) ~= 'string' or #operation < 1 or #operation > 128
                        or operation:find('[%z\1-\31\127]')) then
                        return nil, foundation.error('INVALID_OPERATION', 'Delegated operation name is invalid.', { traceId = traceId })
                    end
                    local targetState = platform.resourceState(targetResource)
                    if targetState ~= 'started' and targetState ~= 'starting' then
                        return nil, foundation.error('DELEGATION_TARGET_UNAVAILABLE',
                            'Capability delegation requires an active direct consumer resource.', {
                                traceId = traceId, retryable = true
                            })
                    end
                    local targetEpoch, targetError = ensureOwner(targetResource)
                    if not targetEpoch then return nil, targetError end
                    return security.capabilities:check(targetResource, capability, {
                        traceId = traceId,
                        operation = ('delegated:%s:%s'):format(caller, operation or capability)
                    })
                end)
            end
        }
        if dataPort then facade.Database = {
            null = function()
                return dataPort:null()
            end,
            read = function(request)
                return guarded(caller, epoch, 'synex.database.read', 'Database.read', function()
                    return dataPort:read(caller, epoch, request)
                end)
            end,
            write = function(request)
                return guarded(caller, epoch, 'synex.database.write', 'Database.write', function()
                    return dataPort:write(caller, epoch, request)
                end)
            end,
            transaction = function(request, handler)
                return guarded(caller, epoch, 'synex.database.transaction',
                    'Database.transaction', function()
                        return dataPort:transaction(caller, epoch, request, handler)
                    end)
            end,
            maintenance = function(request, handler)
                return guarded(caller, epoch, 'synex.database.maintenance',
                    'Database.maintenance', function()
                        return dataPort:maintenance(caller, epoch, request, handler)
                    end)
            end
        } end
        if domainDeletion then facade.DomainDeletions = {
            registerProvider = function(definition)
                return guarded(caller, epoch, 'synex.deletions.provider',
                    'DomainDeletions.registerProvider', function()
                        return domainDeletion:registerProvider(caller, epoch, definition)
                    end)
            end,
            plan = function(request)
                return guarded(caller, epoch, 'synex.deletions.manage',
                    'DomainDeletions.plan', function()
                        return domainDeletion:plan(caller, epoch, request)
                    end)
            end,
            get = function(planId)
                return guarded(caller, epoch, 'synex.deletions.read',
                    'DomainDeletions.get', function()
                        return domainDeletion:get(caller, epoch, planId)
                    end)
            end,
            process = function(planId)
                return guarded(caller, epoch, 'synex.deletions.manage',
                    'DomainDeletions.process', function()
                        return domainDeletion:process(caller, epoch, planId)
                    end)
            end
        } end
        facade.Permissions = {
            defineRole = function(name, permissions, options)
                return guarded(caller, epoch, 'synex.permissions.manage', 'Permissions.defineRole', function(traceId)
                    local validated, optionsError = permissionMutationOptions(options, false, traceId)
                    if not validated then return nil, optionsError end
                    return security.rbac:defineRole(name, permissions, {
                        actor = caller, actorType = 'resource', traceId = traceId,
                        reason = validated.reason
                    })
                end)
            end,
            assign = function(subject, role, options)
                return guarded(caller, epoch, 'synex.permissions.manage', 'Permissions.assign', function(traceId)
                    local validated, optionsError = permissionMutationOptions(options, true, traceId)
                    if not validated then return nil, optionsError end
                    return security.rbac:assign(subject, role, {
                        actor = caller, actorType = 'resource', traceId = traceId,
                        reason = validated.reason, expiresAt = validated.expiresAt
                    })
                end)
            end,
            revoke = function(subject, role, options)
                return guarded(caller, epoch, 'synex.permissions.manage', 'Permissions.revoke', function(traceId)
                    local validated, optionsError = permissionMutationOptions(options, false, traceId)
                    if not validated then return nil, optionsError end
                    return security.rbac:revoke(subject, role, {
                        actor = caller, actorType = 'resource', traceId = traceId,
                        reason = validated.reason
                    })
                end)
            end,
            check = function(subject, permission, explicitDenies)
                return guarded(caller, epoch, 'synex.permissions.read', 'Permissions.check', function()
                    return security.rbac:check(subject, permission, explicitDenies)
                end)
            end,
            explain = function(subject, permission, explicitDenies)
                return guarded(caller, epoch, 'synex.permissions.read', 'Permissions.explain', function()
                    return security.rbac:explain(subject, permission, explicitDenies)
                end)
            end,
            evaluateRules = function(permission, rules)
                return guarded(caller, epoch, 'synex.permissions.read',
                    'Permissions.evaluateRules', function()
                        return security.rbac:evaluateRules(permission, rules)
                    end)
            end
        }
        facade.Access = {
            ban = function(request)
                return guarded(caller, epoch, 'synex.access.manage', 'Access.ban', function(traceId)
                    return mutateAccess(caller, 'access.ban', request, traceId, function(candidate, context)
                        return identity.access:ban(candidate, context)
                    end)
                end)
            end,
            unban = function(request)
                return guarded(caller, epoch, 'synex.access.manage', 'Access.unban', function(traceId)
                    return mutateAccess(caller, 'access.unban', request, traceId, function(candidate, context)
                        return identity.access:unban(candidate, context)
                    end)
                end)
            end,
            allow = function(request)
                return guarded(caller, epoch, 'synex.access.manage', 'Access.allow', function(traceId)
                    return mutateAccess(caller, 'access.allow', request, traceId, function(candidate, context)
                        return identity.access:allow(candidate, context)
                    end)
                end)
            end,
            revokeAllowlist = function(request)
                return guarded(caller, epoch, 'synex.access.manage', 'Access.revokeAllowlist', function(traceId)
                    return mutateAccess(caller, 'access.allow.revoke', request, traceId, function(candidate, context)
                        return identity.access:revokeAllowlist(candidate, context)
                    end)
                end)
            end,
            list = function(request)
                return guarded(caller, epoch, 'synex.access.read', 'Access.list', function()
                    return identity.access:list(request)
                end)
            end
        }
        facade.Events = {
            publish = function(topic, payload, options) return messaging.events:publish(caller, epoch, topic, payload, options) end,
            publishOutbox = function(topic, payload, metadata)
                return guarded(caller, epoch, 'synex.events.durable', 'Events.publishOutbox', function(traceId)
                    if type(metadata) ~= 'table' or getmetatable(metadata) ~= nil then
                        return messaging.events:publishOutbox(caller, epoch, topic, payload, metadata)
                    end
                    local candidate, count = {}, 0
                    for key, value in pairs(metadata) do
                        count = count + 1
                        if count > 4 then
                            return nil, foundation.error('INVALID_OUTBOX_EVENT',
                                'Outbox event metadata contains too many properties.')
                        end
                        candidate[key] = value
                    end
                    if candidate.traceId == nil then candidate.traceId = traceId end
                    return messaging.events:publishOutbox(caller, epoch, topic, payload, candidate)
                end)
            end,
            subscribe = function(topic, handler, options) return messaging.events:subscribe(caller, epoch, topic, handler, options) end
        }
        facade.Hooks = {
            register = function(name, handler, options) return messaging.hooks:register(caller, epoch, name, handler, options) end,
            run = function(name, value, context) return messaging.hooks:run(caller, epoch, name, value, context) end
        }
        facade.Services = {
            provide = function(definition)
                local parsed = type(definition) == 'table' and foundation.semver(definition.version) or nil
                if not parsed or not security.capabilities:providesService(caller, definition.name, parsed.major) then
                    return nil, foundation.error('SERVICE_UNDECLARED', 'The resource manifest does not declare this provided service major.')
                end
                return messaging.services:provide(caller, epoch, definition)
            end,
            setHealth = function(name, version, health)
                return messaging.services:setHealth(caller, epoch, name, version, health)
            end,
            call = function(name, range, method, request, context) return messaging.services:call(caller, epoch, name, range, method, request, context) end
        }
        if controlProviders then facade.ControlProviders = {
            register = function(definition)
                return guarded(caller, epoch, 'synex.control.provider.register',
                    'ControlProviders.register', function()
                        return controlProviders:register(caller, epoch, definition)
                    end)
            end,
            describe = function(namespace)
                return guarded(caller, epoch, 'synex.control.provider.read',
                    'ControlProviders.describe', function()
                        return controlProviders:describe(namespace)
                    end)
            end,
            list = function(request)
                return guarded(caller, epoch, 'synex.control.provider.read',
                    'ControlProviders.list', function()
                        return controlProviders:list(request)
                    end)
            end,
            invoke = function(namespace, operation, request, options)
                return guarded(caller, epoch, 'synex.control.provider.read',
                    'ControlProviders.invoke', function(traceId)
                        return controlProviders:invoke(caller, epoch, namespace,
                            operation, request, options, traceId)
                    end)
            end
        } end
        facade.States = {
            define = function(definition)
                return ownerOperation(caller, epoch, 'States.define', function()
                    return stateService:define(caller, epoch, definition)
                end, foundation.nextId('trace'))
            end,
            get = function(name, subject, context)
                return ownerOperation(caller, epoch, 'States.get', function()
                    return stateService:get(caller, epoch, name, subject, context)
                end, foundation.nextId('trace'))
            end,
            set = function(name, subject, value, context)
                return ownerOperation(caller, epoch, 'States.set', function()
                    return stateService:set(caller, epoch, name, subject, value, context)
                end, foundation.nextId('trace'))
            end,
            clear = function(name, subject, context)
                return ownerOperation(caller, epoch, 'States.clear', function()
                    return stateService:clear(caller, epoch, name, subject, context)
                end, foundation.nextId('trace'))
            end
        }
        facade.Scheduler = {
            after = function(delay, handler, options)
                return ownerOperation(caller, epoch, 'Scheduler.after', function()
                    return lifecycle.scheduler:after(caller, epoch, delay, handler, options)
                end, foundation.nextId('trace'))
            end,
            every = function(delay, handler, options)
                return ownerOperation(caller, epoch, 'Scheduler.every', function()
                    return lifecycle.scheduler:every(caller, epoch, delay, handler, options)
                end, foundation.nextId('trace'))
            end,
            cancel = function(token)
                return ownerOperation(caller, epoch, 'Scheduler.cancel', function()
                    return lifecycle.scheduler:cancel(caller, token), nil
                end, foundation.nextId('trace'))
            end
        }
        facade.Connections = {
            registerGate = function(definition)
                return guarded(caller, epoch, 'synex.connections.gate', 'Connections.registerGate', function()
                    return identity.connections:registerGate(caller, epoch, definition)
                end)
            end
        }
        facade.Idempotency = {
            run = function(operation, key, request, handler, options)
                return ownerOperation(caller, epoch, 'Idempotency.run', function()
                    return reliability.idempotency:run(caller, operation, key, request, handler, options)
                end, foundation.nextId('trace'))
            end
        }
        facade.Outbox = {
            enqueue = function(event)
                return guarded(caller, epoch, 'synex.events.durable', 'Outbox.enqueue', function()
                    local topic = type(event) == 'table' and getmetatable(event) == nil
                        and rawget(event, 'eventType') or nil
                    local authorized, authorizationError = messaging.events:authorizePublisher(
                        caller, epoch, topic)
                    if not authorized then return nil, authorizationError end
                    return reliability.outbox:enqueue(caller, event)
                end)
            end
        }
        facade.Sagas = {
            register = function(definition)
                return guarded(caller, epoch, 'synex.sagas.register', 'Sagas.register', function()
                    return sagaRuntime:register(caller, epoch, definition)
                end)
            end,
            start = function(sagaType, correlationId, context, options)
                return guarded(caller, epoch, 'synex.sagas.write', 'Sagas.start', function(traceId)
                    return sagaRuntime:start(caller, sagaType, correlationId, context, options, traceId)
                end)
            end,
            record = function(publicId, expectedVersion, stepName, eventType, payload, errorValue)
                return guarded(caller, epoch, 'synex.sagas.write', 'Sagas.record', function()
                    return sagaRuntime:record(
                        caller, publicId, expectedVersion, stepName, eventType, payload, errorValue)
                end)
            end,
            get = function(publicId)
                return guarded(caller, epoch, 'synex.sagas.read', 'Sagas.get', function()
                    return sagaRuntime:get(caller, publicId)
                end)
            end
        }
        facade.Audit = {
            append = function(entry)
                return guarded(caller, epoch, 'synex.audit.append', 'Audit.append', function(traceId)
                    local candidate = foundation.copy(entry or {})
                    candidate.actorType = 'resource'
                    candidate.actorId = caller
                    candidate.traceId = candidate.traceId or traceId
                    return reliability.audit:append(candidate)
                end)
            end
        }
        facade.Diagnostics = {
            run = function()
                return guarded(caller, epoch, 'synex.runtime.read', 'Diagnostics.run', function()
                    return runtime:doctor()
                end)
            end,
            getControlSnapshot = function()
                return guarded(caller, epoch, 'synex.runtime.read', 'Diagnostics.getControlSnapshot', function()
                    return runtime:controlSnapshot()
                end)
            end,
            search = function(request)
                return guarded(caller, epoch, 'synex.audit.summary', 'Diagnostics.search', function()
                    return reliability.audit:search(request)
                end)
            end
        }
        for _, namespace in pairs(facade) do
            if type(namespace) == 'table' then
                for name, handler in pairs(namespace) do
                    if type(handler) == 'function' then
                        local guardedHandler = handler
                        namespace[name] = function(...)
                            local available, availabilityError = runtimeGate:requireAvailable()
                            if not available then return false, availabilityError end
                            return foundation.cfxResult(guardedHandler, ...)
                        end
                    end
                end
            end
        end
        return facade
    end
    local function getAPIForCaller(caller, versionRange)
        local available, availabilityError = runtimeGate:requireAvailable()
        if not available then return nil, availabilityError end
        if type(caller) ~= 'string' or caller == '' then
            return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.')
        end
        local epoch, callerError = ensureOwner(caller)
        if not epoch then return nil, callerError end
        if not foundation.semverSatisfies(SynexProtocol.api, versionRange or '^1.0.0') then
            return nil, foundation.error('API_VERSION_UNAVAILABLE', 'No compatible Synex API version is available.')
        end
        local key = caller .. ':' .. epoch
        facadeCache[key] = facadeCache[key] or buildFacade(caller, epoch)
        return facadeCache[key], nil
    end
    local function invokeForCaller(caller, name, version, request, options)
        local available, availabilityError = runtimeGate:requireAvailable()
        if not available then return nil, availabilityError end
        if type(caller) ~= 'string' or caller == '' then
            return nil, foundation.error('CALLER_REQUIRED', 'External Synex exports require an invoking resource.')
        end
        local epoch, callerError = ensureOwner(caller)
        if not epoch then return nil, callerError end
        local prepared, optionsError = rpcCallOptions(options)
        if not prepared then return nil, optionsError end
        return messaging.gateway:invoke(caller, epoch, name, version, request, prepared)
    end
    function runtime:getAPI(versionRange)
        local caller, _, callerError = requireCaller()
        if not caller then return nil, callerError end
        return getAPIForCaller(caller, versionRange)
    end
    function runtime:invoke(name, version, request, options)
        local caller, _, callerError = requireCaller()
        if not caller then return nil, callerError end
        return invokeForCaller(caller, name, version, request, options)
    end
    return {
        getAPIForCaller = getAPIForCaller,
        guarded = guarded,
        invokeForCaller = invokeForCaller,
        registerCoreContracts = registerCoreContracts,
        registerCoreServices = registerCoreServices
    }
end
