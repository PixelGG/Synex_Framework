return function(Foundation, modules)
local domainError = Foundation.domainError
local function createDataPortPersistence(deps)
    local jsonEncode = assert(type(deps.jsonEncode) == 'function' and deps.jsonEncode,
        'groups persistence requires jsonEncode')
    local jsonDecode = assert(type(deps.jsonDecode) == 'function' and deps.jsonDecode,
        'groups persistence requires jsonDecode')
    local nextId = assert(type(deps.nextId) == 'function' and deps.nextId,
        'groups persistence requires nextId')
    local evaluator = assert(type(deps.capabilityEvaluator) == 'table'
        and type(deps.capabilityEvaluator.evaluate) == 'function' and deps.capabilityEvaluator,
        'groups persistence requires capabilityEvaluator')
    local policyEngine = assert(type(deps.policyEngine) == 'table'
        and type(deps.policyEngine.decide) == 'function' and deps.policyEngine,
        'groups persistence requires policyEngine')
    local cache = assert(type(deps.cache) == 'table' and deps.cache,
        'groups persistence requires cache')
    local registries = assert(type(deps.registries) == 'table' and deps.registries,
        'groups persistence requires registries')
    local applicationSchemas = assert(type(deps.applicationSchemas) == 'table'
        and type(deps.applicationSchemas.validateSchema) == 'function'
        and type(deps.applicationSchemas.validateData) == 'function'
        and deps.applicationSchemas,
        'groups persistence requires applicationSchemas')
    local validateOperation = assert(type(deps.validateOperation) == 'function'
        and deps.validateOperation, 'groups persistence requires validateOperation')
    local checkCorePermission = assert(type(deps.checkCorePermission) == 'function'
        and deps.checkCorePermission, 'groups persistence requires checkCorePermission')
    local applyRegistryMutation = deps.applyRegistryMutation
    if applyRegistryMutation == nil then
        applyRegistryMutation = function(mutation)
            local registry = registries[mutation.registry]
            if type(registry) ~= 'table' or type(registry.replace) ~= 'function' then
                return nil, domainError('REGISTRY_ENTRY_INVALID',
                    'The extension registry is unavailable.')
            end
            return registry:replace(
                mutation.owner, mutation.epoch, mutation.key, mutation.value)
        end
    elseif type(applyRegistryMutation) ~= 'function' then
        error('groups persistence requires a callable registry mutation coordinator')
    end
    local refreshRegistry = deps.refreshRegistry
    if refreshRegistry ~= nil and type(refreshRegistry) ~= 'function' then
        error('groups persistence requires a callable registry refresh coordinator')
    end
    local observeRegistryOwner = deps.observeRegistryOwner
    if observeRegistryOwner ~= nil and type(observeRegistryOwner) ~= 'function' then
        error('groups persistence requires a callable registry owner observer')
    end
    local isRegistryOwnerEpochActive = deps.isRegistryOwnerEpochActive
    if isRegistryOwnerEpochActive == nil then
        isRegistryOwnerEpochActive = function() return true end
    elseif type(isRegistryOwnerEpochActive) ~= 'function' then
        error('groups persistence requires a callable registry owner epoch fence')
    end
    local registryMutationOperations = {
        registries_begin = true,
        types_register = true,
        relation_types_register = true,
        duty_states_register = true,
        attributes_register_schema = true
    }
    local runtimeIndex = assert(type(deps.runtimeIndex) == 'table'
        and type(deps.runtimeIndex.snapshot) == 'function' and deps.runtimeIndex,
        'groups persistence requires the runtime index')
    local canonicalEncode = Foundation.createCanonicalEncoder(jsonEncode)
    local dataPort = assert(type(deps.dataPort) == 'table' and deps.dataPort,
        'groups persistence requires the Core database adapter')
    assert(type(dataPort.readOrError) == 'function'
        and type(dataPort.adaptTransaction) == 'function'
        and type(dataPort.transaction) == 'function'
        and type(dataPort.maintenance) == 'function',
        'groups persistence requires a complete Core database adapter')
    local function rows(sql, parameters)
        return dataPort:readOrError(sql, parameters, {
            maximumRows = 8192,
            maximumResultBytes = 4194304,
            timeoutMs = 15000
        })
    end
    local function one(sql, parameters) return rows(sql, parameters)[1] end
    local function update(sql, parameters)
        local result = dataPort:writeOrError(sql, parameters, { timeoutMs = 15000 })
        local changed = type(result) == 'table' and tonumber(result.affectedRows) or nil
        if not changed or math.type(changed) ~= 'integer' or changed < 0 then
            error(domainError('DATABASE_RESULT_INVALID',
                'The Groups database write returned an invalid affected-row count.'), 0)
        end
        return changed
    end
    local function maintenance(operation, handler, maximumStatements)
        local response, operationError = dataPort:maintenance(operation, function(tx)
            local called, result, resultError = pcall(handler, tx)
            if not called then
                return nil, type(result) == 'table' and result or domainError(
                    'DATABASE_ERROR', 'The Groups maintenance transaction failed.', true)
            end
            if result ~= true then
                return nil, resultError or domainError('DATABASE_ERROR',
                    'The Groups maintenance transaction was rejected.', true)
            end
            return true, nil
        end, {
            timeoutMs = 15000,
            maximumRows = 8192,
            maximumResultBytes = 4194304,
            maximumResponseBytes = 1048576,
            maximumStatements = maximumStatements or 4096
        })
        if response == true then return true, nil end
        return nil, operationError
    end
    local function readAdapter()
        local transaction = {}
        function transaction.query(sql, parameters)
            return rows(sql, parameters)
        end
        transaction.many = transaction.query
        function transaction.one(sql, parameters)
            return rows(sql, parameters)[1]
        end
        function transaction.affected()
            error(domainError('DATABASE_ACCESS_MISMATCH',
                'A Groups read operation cannot modify persistent state.'), 0)
        end
        transaction.update = transaction.affected
        transaction.insert = transaction.affected
        return transaction
    end
    local function safeId(namespace)
        local value, idError = nextId(namespace)
        if value == false and type(idError) == 'table' then value = nil end
        if not Foundation.isPublicId(value) or value ~= value:lower()
            or not value:match('^[a-z][a-z0-9_]*$') then
            return nil, idError or domainError('ID_ALLOCATION_FAILED',
                'Synex Core did not allocate a valid Groups identifier.', true)
        end
        return value, nil
    end
    local createEffectWriter = assert(modules and type(modules.effects) == 'function'
        and modules.effects(Foundation), 'groups persistence requires effects')
    local writeEffect = createEffectWriter({ jsonEncode = jsonEncode, safeId = safeId })
    local function reasonCode(value, fallback)
        if type(value) == 'string' then
            local candidate = value:lower():gsub('[^a-z0-9_.:%-]+', '_'):gsub('_+', '_')
                :gsub('^[_%.:%-]+', ''):gsub('[_%.:%-]+$', '')
            if #candidate >= 2 and #candidate <= 64
                and candidate:match('^[a-z][a-z0-9_.:%-]+$') then
                return candidate
            end
        end
        return fallback or 'requested_change'
    end
    local function success(entityId, entityType, status, version)
        return {
            entity_id = entityId,
            entity_type = entityType,
            status = status,
            version = tonumber(version) or 1,
            replayed = false
        }
    end
    local function effect(action, entityType, entityId, groupId, characterId,
        before, after, reason, version)
        return {
            action = action,
            eventType = 'synex.groups.' .. action,
            entityType = entityType,
            entityId = entityId,
            groupId = groupId,
            characterId = characterId,
            before = before,
            after = after,
            reason = reasonCode(reason, action:gsub('%.', '_')),
            version = tonumber(version) or tonumber(after and after.version) or 1
        }
    end
    local storedPolicyEvaluator
    local runtime
    local authorizationPreflightSeal = {}
    local createCapabilityAccess = assert(modules
        and type(modules.capability_access) == 'function'
        and modules.capability_access(Foundation),
        'groups persistence requires capability_access')
    local capabilityAccess = createCapabilityAccess({
        evaluator = evaluator,
        getStoredPolicyEvaluator = function() return storedPolicyEvaluator end,
        getRuntime = function() return runtime end
    })
    assert(type(capabilityAccess) == 'table'
        and type(capabilityAccess.definitionCache) == 'table'
        and Foundation.isCallable(capabilityAccess.authorize)
        and Foundation.isCallable(capabilityAccess.evaluateCharacter)
        and Foundation.isCallable(capabilityAccess.invalidateDefinitions)
        and Foundation.isCallable(capabilityAccess.clearDefinitions)
        and Foundation.isCallable(capabilityAccess.definitionCacheSnapshot),
        'groups persistence capability access is incomplete')
    runtime = {
        id = safeId,
        reason = reasonCode,
        success = success,
        effect = effect,
        authorize = capabilityAccess.authorize,
        evaluateCharacter = capabilityAccess.evaluateCharacter,
        policyEngine = policyEngine,
        cache = cache,
        definitionCache = capabilityAccess.definitionCache,
        registries = registries,
        applicationSchemas = applicationSchemas,
        jsonEncode = jsonEncode,
        jsonDecode = jsonDecode,
        checkCorePermission = checkCorePermission,
        validateOperation = validateOperation,
        runtimeIndex = runtimeIndex
    }
    function runtime.completeAuthorizationPreflight(context)
        if type(context) == 'table'
            and rawget(context, 'authorizationPreflight') == authorizationPreflightSeal then
            return authorizationPreflightSeal
        end
        return nil
    end
    function runtime.requireRegistryOwnerEpoch(owner, epoch)
        local called, active = pcall(isRegistryOwnerEpochActive, owner, epoch)
        if not called then
            return nil, domainError('DATABASE_ERROR',
                'The extension registry owner epoch fence is unavailable.', true)
        end
        if active ~= true then
            return nil, domainError('STALE_RESOURCE',
                'The extension registry owner epoch has stopped.')
        end
        return true, nil
    end
    function runtime.requireRegistryOwnerSession(tx, owner, epoch)
        if type(tx) ~= 'table' or not Foundation.isCallable(tx.one)
            or type(owner) ~= 'string' or type(epoch) ~= 'number'
            or math.type(epoch) ~= 'integer' or epoch < 1 then
            return nil, domainError('VALIDATION_FAILED',
                'The extension registry synchronization context is invalid.')
        end
        local current, currentError = runtime.requireRegistryOwnerEpoch(owner, epoch)
        if not current then return nil, currentError end
        local session = tx.one([[SELECT `owner_epoch`, `generation`, `active`
            FROM `synex_group_registry_owner_syncs`
            WHERE `owner_resource` = ? FOR UPDATE]], { owner })
        current, currentError = runtime.requireRegistryOwnerEpoch(owner, epoch)
        if not current then return nil, currentError end
        if not session then
            return nil, domainError('STALE_RESOURCE',
                'The extension owner must begin synchronization before registration.')
        end
        local storedEpoch = tonumber(session.owner_epoch)
        local generation = tonumber(session.generation)
        local active = tonumber(session.active)
        if not storedEpoch or math.type(storedEpoch) ~= 'integer' or storedEpoch < 1
            or not generation or math.type(generation) ~= 'integer' or generation < 1
            or active ~= 0 and active ~= 1 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The stored extension registry synchronization session is invalid.', true)
        end
        if active ~= 1 or storedEpoch ~= epoch then
            return nil, domainError('STALE_RESOURCE',
                'The extension owner synchronization session is no longer active.')
        end
        return { ownerEpoch = storedEpoch, generation = generation }, nil
    end
    function runtime.deferRegistry(context, registry, owner, epoch, generation, key, value)
        if type(context) ~= 'table' or type(context.registryMutations) ~= 'table'
            or context.caller ~= owner or context.callerEpoch ~= epoch
            or type(generation) ~= 'number' or math.type(generation) ~= 'integer'
            or generation < 1
            or type(registry) ~= 'string' or type(key) ~= 'string'
            or type(value) ~= 'table' or #context.registryMutations >= 8 then
            return nil, domainError('REGISTRY_ENTRY_INVALID',
                'The extension registry mutation is not bound to the current owner generation.')
        end
        local target = registries[registry]
        if type(target) ~= 'table' or type(target.get) ~= 'function' then
            return nil, domainError('REGISTRY_ENTRY_INVALID',
                'The extension registry target is unavailable.')
        end
        local _, lookupError, metadata = target:get(key)
        if metadata and metadata.owner ~= owner then
            return nil, domainError('TYPE_OWNER_CONFLICT',
                'The extension registry key belongs to another owner.')
        end
        if not metadata and lookupError and lookupError.code ~= 'REGISTRY_KEY_NOT_FOUND' then
            return nil, lookupError
        end
        local stats = type(target.stats) == 'function' and target:stats() or nil
        if not metadata and type(stats) == 'table'
            and stats.entries >= stats.maximumEntries then
            return nil, domainError('REGISTRY_CAPACITY_EXCEEDED',
                'The extension registry has reached its configured capacity.')
        end
        if not metadata and type(target.listOwner) == 'function' then
            local owned, ownerError = target:listOwner(owner, epoch)
            if not owned then return nil, ownerError end
            if type(stats) == 'table' and #owned >= stats.maximumPerOwner then
                return nil, domainError('REGISTRY_OWNER_CAPACITY_EXCEEDED',
                    'The extension registry owner has reached its configured capacity.')
            end
        end
        context.registryMutations[#context.registryMutations + 1] = {
            registry = registry, owner = owner, epoch = epoch,
            generation = generation, key = key,
            value = Foundation.copyPlain(value, { preserveContainerKind = false })
        }
        return true, nil
    end
    function runtime.requireGroup(tx, publicId, lock)
        local row = tx.one([[SELECT group_record.id, group_record.public_id,
                group_record.group_key, group_record.display_name, group_record.group_type,
                group_record.status, group_record.metadata_json, group_record.version,
                profile.group_type_id, profile.slug, profile.visibility,
                profile.lifecycle_state, profile.version AS profile_version,
                type_record.type_key, type_record.schema_version AS type_schema_version,
                type_record.metadata_json AS type_metadata_json
            FROM synex_groups AS group_record
            INNER JOIN synex_group_organization_profiles AS profile
                ON profile.group_id = group_record.id
            INNER JOIN synex_group_types AS type_record
                ON type_record.id = profile.group_type_id
            WHERE group_record.public_id = ?]]
                .. (lock and ' FOR UPDATE' or ''), { publicId })
        if not row then return nil, domainError('GROUP_NOT_FOUND', 'The group does not exist.') end
        return row, nil
    end
    function runtime.requireMembership(tx, publicId, lock)
        local row = tx.one([[SELECT membership.id, membership.public_id,
                membership.group_id, membership.version,
                profile.character_id, profile.lifecycle_state,
                profile.visibility, profile.joined_at,
                profile.version AS profile_version,
                group_record.public_id AS group_public_id
            FROM synex_group_memberships AS membership
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = membership.id
            INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
            WHERE membership.public_id = ?]]
                .. (lock and ' FOR UPDATE' or ''), { publicId })
        if not row then
            return nil, domainError('MEMBERSHIP_NOT_FOUND', 'The membership does not exist.')
        end
        return row, nil
    end
    function runtime.touchGroup(tx, internalId)
        local changed = tx.affected([[UPDATE synex_group_read_model_versions
            SET model_version = model_version + 1,
                invalidated_at = CURRENT_TIMESTAMP(6)
            WHERE group_id = ?]], { internalId })
        if changed ~= 1 then
            return nil, domainError('CONCURRENT_MODIFICATION',
                'The group read-model revision could not be advanced.', true)
        end
        return true, nil
    end
    local handlers = { read = {}, execute = {} }
    for _, name in ipairs({
        'organizations_read', 'organizations_creation', 'organizations_lifecycle',
        'organizations_creation_approvals', 'organizations_deletion',
        'organizations_types',
        'extension_registries', 'organizations_structure',
        'memberships_read', 'memberships_invitations', 'memberships_lifecycle',
        'memberships_access', 'memberships_reporting', 'compatibility',
        'membership_transition_policies',
        'governance_capabilities', 'governance_capability_rules', 'governance_policies',
        'governance_attributes', 'governance_attribute_activation',
        'governance_definitions', 'workflows_duty',
        'workflows_assignments', 'workflow_reads',
        'workflows_applications', 'workflows_proposals',
        'diagnostics'
    }) do
        local factory = modules and modules[name]
        if factory ~= nil then
            local built = factory(Foundation)
            for operation, handler in pairs(built.read or {}) do
                if handlers.read[operation] then error('duplicate Groups read handler: ' .. operation) end
                handlers.read[operation] = handler
            end
            for operation, handler in pairs(built.execute or {}) do
                if handlers.execute[operation] then
                    error('duplicate Groups mutation handler: ' .. operation)
                end
                handlers.execute[operation] = handler
            end
            if built.evaluateStoredPolicy ~= nil then
                if storedPolicyEvaluator ~= nil then
                    error('duplicate Groups stored policy evaluator')
                end
                if type(built.evaluateStoredPolicy) ~= 'function' then
                    error('invalid Groups stored policy evaluator')
                end
                storedPolicyEvaluator = built.evaluateStoredPolicy
            end
            if built.enforceMembershipActivation ~= nil then
                if runtime.enforceMembershipActivation ~= nil
                    or not Foundation.isCallable(built.enforceMembershipActivation) then
                    error('invalid or duplicate Groups membership activation enforcer')
                end
                runtime.enforceMembershipActivation = built.enforceMembershipActivation
            end
            if built.resolveMembershipTransitionPolicy ~= nil then
                if runtime.resolveMembershipTransitionPolicy ~= nil
                    or not Foundation.isCallable(built.resolveMembershipTransitionPolicy) then
                    error('invalid or duplicate Groups membership transition policy resolver')
                end
                runtime.resolveMembershipTransitionPolicy = built.resolveMembershipTransitionPolicy
            end
        end
    end
    local installApprovedOperations = assert(modules
        and type(modules.approved_operations) == 'function' and modules.approved_operations,
        'groups persistence requires approved_operations')
    installApprovedOperations(runtime, {
        Foundation = Foundation, domainError = domainError,
        canonicalEncode = canonicalEncode, jsonDecode = jsonDecode,
        validateOperation = validateOperation, executeHandlers = handlers.execute
    })
    assert(Foundation.isCallable(runtime.validateApproved)
        and Foundation.isCallable(runtime.resolveApprovedOperation)
        and Foundation.isCallable(runtime.verifyApprovedOperation)
        and Foundation.isCallable(runtime.invokeApproved),
        'groups persistence approved operations are incomplete')
    local port = {}

    function port:invalidateDefinitionCache(groupId)
        if not Foundation.isPublicId(groupId) then
            return 0
        end
        return capabilityAccess.invalidateDefinitions(groupId)
    end

    function port:clearDefinitionCache()
        return capabilityAccess.clearDefinitions()
    end

    function port:definitionCacheSnapshot()
        return capabilityAccess.definitionCacheSnapshot()
    end

    function port:read(operation, request, context)
        local handler = handlers.read[operation]
        if type(handler) ~= 'function' then
            return nil, domainError('OPERATION_UNAVAILABLE',
                'The requested Groups read operation is unavailable.', true)
        end
        local ok, value, operationError, effects = pcall(
            handler, readAdapter(), request, runtime, context)
        if not ok then
            return nil, type(value) == 'table' and value or domainError(
                'DATABASE_ERROR', 'The Groups read operation failed.', true)
        end
        return value, operationError, effects
    end
    function port:preflight(operation, request, context)
        local handler = handlers.execute[operation]
        if type(handler) ~= 'function' then
            return nil, domainError('OPERATION_UNAVAILABLE',
                'The requested Groups authorization preflight is unavailable.', true)
        end
        local preflightContext = {}
        for key, value in pairs(context or {}) do preflightContext[key] = value end
        preflightContext.authorizationPreflight = authorizationPreflightSeal

        -- Handlers must stop at completeAuthorizationPreflight before their
        -- first write.  This adapter deliberately makes every write primitive
        -- unavailable so an omitted stop can never mutate state.
        local adapter = readAdapter()
        function adapter.query()
            error(domainError('DATABASE_ACCESS_MISMATCH',
                'A Groups authorization preflight cannot modify persistent state.'), 0)
        end
        adapter.affected = adapter.query
        adapter.update = adapter.query
        adapter.insert = adapter.query

        local called, response, operationError = pcall(
            handler, adapter, request, runtime, preflightContext)
        if not called then
            return nil, type(response) == 'table' and response or domainError(
                'DATABASE_ERROR', 'The Groups authorization preflight failed.', true)
        end
        if response == authorizationPreflightSeal then return true, nil end
        if response ~= nil then
            return nil, domainError('DATABASE_ERROR',
                'The Groups authorization preflight did not stop at its authority boundary.', true)
        end
        if type(operationError) == 'table'
            and (operationError.retryable == true
                or operationError.code == 'CORE_UNAVAILABLE'
                or operationError.code == 'READ_MODEL_TOO_LARGE') then
            return nil, domainError('DATABASE_ERROR',
                'The Groups authorization preflight is temporarily unavailable.',
                operationError.retryable == true)
        end
        return nil, domainError('INSUFFICIENT_PERMISSION',
            'The actor character may not perform this Groups operation.')
    end
    function port:execute(operation, request, context)
        local handler = handlers.execute[operation]
        if type(handler) ~= 'function' then
            return nil, domainError('OPERATION_UNAVAILABLE',
                'The requested Groups mutation is unavailable.', true)
        end
        local canonicalOk = pcall(canonicalEncode, request)
        if not canonicalOk then
            return nil, domainError('VALIDATION_FAILED',
                'The Groups mutation request could not be canonicalized.')
        end
        if operation == 'registries_begin' and observeRegistryOwner then
            local observed, observationError = observeRegistryOwner(
                context and context.caller, context and context.callerEpoch)
            if not observed then
                return nil, observationError or domainError('DATABASE_ERROR',
                    'The registry owner epoch could not be observed.', true)
            end
        end
        local executionContext = {}
        for key, value in pairs(context or {}) do executionContext[key] = value end
        executionContext.registryMutations = {}
        local envelope, transactionError, transactionMetadata = dataPort:transaction({
            operation = 'groups.' .. operation,
            idempotencyKey = request.idempotency_key,
            request = request,
            timeoutMs = 15000,
            maximumRows = 8192,
            maximumResultBytes = 4194304,
            maximumRequestBytes = 8388608,
            maximumResponseBytes = 4194304,
            maximumStatements = 4096
        }, function(tx)
            local handlerOk, response, operationError, effects = pcall(
                handler, tx, request, runtime, executionContext)
            if not handlerOk then
                return nil, type(response) == 'table' and response or domainError(
                    'DATABASE_ERROR', 'The Groups operation failed unexpectedly.', true)
            end
            if not response then return nil, operationError end
            effects = type(effects) == 'table' and effects or {}
            for _, item in ipairs(effects) do
                local written, writeError = writeEffect(tx, item, request, context)
                if not written then
                    return nil, writeError
                end
            end
            if registryMutationOperations[operation] then
                local current, currentError = runtime.requireRegistryOwnerEpoch(
                    executionContext.caller, executionContext.callerEpoch)
                if not current then return nil, currentError end
            end
            if response.replayed ~= nil then response.replayed = false end
            return {
                response = response,
                effects = effects,
                registryMutations = executionContext.registryMutations
            }, nil
        end)
        if not envelope then return nil, transactionError end
        if type(envelope) ~= 'table' or type(envelope.response) ~= 'table'
            or type(envelope.effects) ~= 'table'
            or type(envelope.registryMutations) ~= 'table' then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The Core transaction returned an invalid Groups envelope.')
        end
        local replayed = type(transactionMetadata) == 'table'
            and transactionMetadata.replayed == true
        if replayed then
            if envelope.response.replayed ~= nil then envelope.response.replayed = true end
            if refreshRegistry then
                local refreshed, refreshError = refreshRegistry(
                    operation, request, context, envelope.response,
                    envelope.registryMutations)
                if not refreshed then return nil, refreshError end
            end
            return envelope.response, nil, {}
        end
        for _, committedEffect in ipairs(envelope.effects) do
            if type(committedEffect) == 'table'
                and Foundation.isPublicId(committedEffect.groupId) then
                capabilityAccess.invalidateDefinitions(committedEffect.groupId)
            end
        end
        local registryError
        -- When a canonical refresh is available, never expose a delayed
        -- transaction envelope first. A newer begin generation may already
        -- have retired its row while this post-commit continuation waited.
        if not refreshRegistry then
            for _, mutation in ipairs(envelope.registryMutations) do
                local synchronized, synchronizationError = applyRegistryMutation(mutation)
                if not synchronized then
                    registryError = synchronizationError or domainError('DATABASE_ERROR',
                        'A committed extension registry mutation could not be synchronized.', true)
                    break
                end
            end
        end
        if refreshRegistry then
            local refreshed, refreshError = refreshRegistry(
                operation, request, executionContext, envelope.response,
                envelope.registryMutations)
            if not refreshed then return nil, refreshError or registryError end
            registryError = nil
        end
        if registryError then return nil, registryError end
        return envelope.response, nil, envelope.effects
    end
    if modules and type(modules.workers) == 'function' then
        modules.workers(port, {
            Foundation = Foundation,
            domainError = domainError,
            jsonDecode = jsonDecode,
            jsonEncode = jsonEncode,
            many = rows,
            update = update,
            cache = cache,
            effect = effect,
            id = safeId,
            writeEffect = writeEffect,
            withTransaction = function(handler)
                return maintenance('groups.worker_maintenance', handler, 4096)
            end
        })
    end
    if modules and type(modules.deletions) == 'function' then
        modules.deletions(port, {
            Foundation = Foundation,
            domainError = domainError,
            many = rows,
            cache = cache,
            effect = effect,
            id = safeId,
            writeEffect = writeEffect,
            withTransaction = function(handler)
                return maintenance('groups.domain_deletion', handler, 4096)
            end
        })
    end
    if modules and type(modules.observability) == 'function' then
        modules.observability(port, {
            domainError = domainError,
            jsonEncode = jsonEncode,
            many = rows,
            one = one,
            random = math.random,
            cache = cache,
            uuidV4 = Foundation.uuidV4,
            withTransaction = function(handler)
                return maintenance('groups.lifecycle', function(tx)
                    return handler(function(sql, parameters)
                        return tx.query(sql, parameters)
                    end)
                end, 4096)
            end
        })
    end
    return port
end
return createDataPortPersistence
end
