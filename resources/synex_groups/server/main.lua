local Foundation = require 'server.foundation'
local createCache = require('server.cache')(Foundation)
local Validation = require('server.validation')(Foundation)
local Constants = require 'server.domain.constants'
local Lifecycle = require 'server.domain.lifecycle'
local Graph = require 'server.domain.graph'
local Capabilities = require 'server.domain.capabilities'
local Policy = require 'server.domain.policy'
local Registry = require 'server.domain.registry'
local createExtensionRegistryCoordinator = require('server.extension_registries')(Foundation)
local ApplicationSchemas = require('server.domain.application_schema')(Foundation)
local createDatabaseAdapter = require('server.database_adapter')(Foundation)
local createRuntimeIndex = require('server.runtime_index')(Foundation)
local createRuntimeContextLoader = require('server.persistence.runtime_context')(Foundation)
local createOutboxDispatcher = require('server.outbox')(Foundation)
local createService = require('server.service')(Foundation)
local createGroupCreationApprovals = require('server.group_creation_approvals')(Foundation)
local createGroupDeletions = require('server.group_deletions')(Foundation)
local scheduleWorkers = require('server.scheduler')(Foundation)
local sanitizeRuntimeErrorEvent = require('server.runtime_error')(Foundation)
local createJsonRuntime = require 'server.json_runtime'
local CoreBootstrap = require('server.core_bootstrap')(Foundation)
local createControlProvider = require('server.control_provider')(Foundation)
local persistenceModules = {
    effects = require 'server.persistence.effects', approved_operations = require 'server.persistence.approved_operations', capability_access = require 'server.persistence.capability_access',
    organizations_read = require 'server.persistence.organizations_read', organizations_creation = require 'server.persistence.organizations_creation',
    organizations_lifecycle = require 'server.persistence.organizations_lifecycle', organizations_creation_approvals = require 'server.persistence.organizations_creation_approvals',
    organizations_deletion = require 'server.persistence.organizations_deletion', organizations_types = require 'server.persistence.organizations_types',
    extension_registries = require 'server.persistence.extension_registries', organizations_structure = require 'server.persistence.organizations_structure',
    memberships_read = require 'server.persistence.memberships_read', memberships_invitations = require 'server.persistence.memberships_invitations',
    memberships_lifecycle = require 'server.persistence.memberships_lifecycle',
    membership_transition_policies =
        require 'server.persistence.membership_transition_policies',
    memberships_access = require 'server.persistence.memberships_access', memberships_reporting = require 'server.persistence.memberships_reporting',
    governance_capabilities = require 'server.persistence.governance_capabilities', governance_capability_rules = require 'server.persistence.governance_capability_rules',
    governance_policies = require 'server.persistence.governance_policies', governance_attributes = require 'server.persistence.governance_attributes',
    governance_attribute_activation =
        require 'server.persistence.governance_attribute_activation',
    governance_definitions = require 'server.persistence.governance_definitions', workflows_duty = require 'server.persistence.workflows_duty',
    workflows_assignments = require 'server.persistence.workflows_assignments', workflow_reads = require 'server.persistence.workflow_reads',
    workflows_applications = require 'server.persistence.workflows_applications', workflows_proposals = require 'server.persistence.workflows_proposals',
    diagnostics = require 'server.persistence.diagnostics', workers = require 'server.persistence.workers',
    deletions = require 'server.persistence.deletions', observability = require 'server.persistence.observability'
}
local createDataPortPersistence = require('server.persistence')(Foundation, persistenceModules)
local loadContractDefinitions = require('server.contracts')(Foundation)
local module = {
    Foundation = Foundation, Validation = Validation, Constants = Constants,
    Lifecycle = Lifecycle, Graph = Graph, Capabilities = Capabilities,
    Policy = Policy, Registry = Registry,
    createExtensionRegistryCoordinator = createExtensionRegistryCoordinator,
    ApplicationSchemas = ApplicationSchemas, createDatabaseAdapter = createDatabaseAdapter,
    createRuntimeIndex = createRuntimeIndex, createRuntimeContextLoader = createRuntimeContextLoader,
    createCache = createCache, createService = createService,
    createGroupCreationApprovals = createGroupCreationApprovals,
    createGroupDeletions = createGroupDeletions, createDataPortPersistence = createDataPortPersistence,
    createOutboxDispatcher = createOutboxDispatcher, loadContractDefinitions = loadContractDefinitions
}
module.createControlProvider = createControlProvider
module.sanitizeRuntimeErrorEvent = sanitizeRuntimeErrorEvent
if rawget(_G, 'SYNEX_TEST_MODE') == true then return module end
local JsonRuntime = createJsonRuntime(json)
local encode = JsonRuntime.encode
local decode = JsonRuntime.decode
local function runtimeErrorSink(event)
    print(encode(sanitizeRuntimeErrorEvent(event)))
end
local rawCatalog = LoadResourceFile('synex_groups', 'groups.contracts.json')
local definitions, catalogError = loadContractDefinitions(rawCatalog, decode)
if not definitions then
    error(('synex_groups contract catalog failed validation: %s'):format(
        catalogError and catalogError.message or 'unknown error'))
end
local currentApi
local cache = createCache({ maximum = 1024, ttlMs = 5000 })
local function requireCurrentApi(section, method)
    local api = currentApi
    if not api or type(api[section]) ~= 'table' or not Foundation.isCallable(api[section][method]) then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            ('Synex Core %s.%s is unavailable.'):format(section, method), true)
    end
    return api[section][method], nil
end
local function acquireCoreApi()
    local invoked, api, apiError = pcall(function()
        return exports.synex_core:GetAPI(Foundation.API_RANGE)
    end)
    if not invoked then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'synex_groups could not reach the Synex API export.', true)
    end
    if not api then
        return nil, apiError or Foundation.domainError('CORE_UNAVAILABLE',
            'synex_groups could not acquire the Synex API.', true)
    end
    if not CoreBootstrap.validateApi(api) then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'synex_groups requires the Core database, lifecycle, event, scheduler, identity, hook, audit, permission, service, and RPC APIs.', true)
    end
    return api, nil
end
local function bootstrapRuntime()
local databaseApi = {}
for _, methodName in ipairs({ 'null', 'read', 'write', 'transaction', 'maintenance' }) do
    local method = methodName
    databaseApi[method] = function(...)
        local callable, apiError = requireCurrentApi('Database', method)
        if not callable then return nil, apiError end
        return callable(...)
    end
end
local coreDataPort = createDatabaseAdapter(databaseApi)
local runtimeIndex = createRuntimeIndex({
    maximumCharacters = 4096,
    maximumMemberships = 131072,
    maximumMembershipsPerCharacter = 1024
})
local runtimeContextLoader = createRuntimeContextLoader({
    maximumMembershipsPerCharacter = 1024,
    query = function(sql, parameters)
        return coreDataPort:readOrError(sql, parameters, {
            maximumRows = 1025,
            maximumResultBytes = 4194304,
            timeoutMs = 15000
        })
    end
})
local runtimeRebuildJournal
local function loadRuntimeCharacter(characterId)
    return runtimeContextLoader:loadCharacter(characterId)
end
local function recordRuntimeMutation(characterId, context)
    if runtimeRebuildJournal ~= nil then
        runtimeRebuildJournal[characterId] = context or false
    end
end
local function replaceRuntimeCharacter(characterId, context)
    local replaced, replaceError = runtimeIndex:replaceCharacter(characterId, context)
    if not replaced then return nil, replaceError end
    recordRuntimeMutation(characterId, context)
    return true, nil
end
local function removeRuntimeCharacter(characterId)
    local removed = runtimeIndex:removeCharacter(characterId)
    recordRuntimeMutation(characterId, false)
    return removed
end
local function applyRuntimeEffect(effect)
    if type(effect) == 'table' and (effect.action == 'type.registered'
        or effect.action == 'duty_state.registered') then
        return runtimeIndex:refreshAll(loadRuntimeCharacter)
    end
    if type(effect) == 'table' and effect.action == 'group.suspended'
        and Foundation.isPublicId(effect.groupId) then
        return runtimeIndex:refreshGroup(effect.groupId, loadRuntimeCharacter)
    end
    return runtimeIndex:applyEffect(effect, loadRuntimeCharacter)
end
local function applyCoordinatorEffects(effects)
    if type(effects) ~= 'table' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'Committed Groups effects are invalid.', true)
    end
    for _, effect in ipairs(effects) do
        if type(effect) ~= 'table' then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'A committed Groups effect is invalid.', true)
        end
        if type(effect.groupId) == 'string' then
            cache:invalidatePrefix('group:' .. effect.groupId)
            cache:invalidatePrefix('directory:' .. effect.groupId)
        end
        if type(effect.characterId) == 'string' then
            cache:invalidatePrefix('character:' .. effect.characterId)
        end
        if type(effect.entityId) == 'string' and effect.entityType == 'membership' then
            cache:invalidatePrefix('membership:' .. effect.entityId)
        end
        local applied, applyError = applyRuntimeEffect(effect)
        if not applied then return nil, applyError end
    end
    return true, nil
end
local registries = {
    groupTypes = Registry.create({ maximumEntries = 1024, maximumPerOwner = 128 }),
    relationTypes = Registry.create({ maximumEntries = 1024, maximumPerOwner = 128 }),
    attributeSchemas = Registry.create({ maximumEntries = 2048, maximumPerOwner = 256 }),
    dutyStates = Registry.create({ maximumEntries = 256, maximumPerOwner = 64 })
}
local function isExtensionOwnerRunning(owner)
    local state = GetResourceState(owner)
    return state == 'starting' or state == 'started'
end
local extensionRegistries = createExtensionRegistryCoordinator({
    registries = registries,
    query = function(sql, parameters)
        return coreDataPort:readOrError(sql, parameters, {
            maximumRows = 8192, maximumResultBytes = 4194304, timeoutMs = 15000
        })
    end,
    startTransaction = function(handler)
        local committed = coreDataPort:maintenance('groups.extension_registry', function(tx)
            local called, result = pcall(handler, function(sql, parameters)
                return tx.query(sql, parameters)
            end)
            if not called then
                return nil, type(result) == 'table' and result
                    or Foundation.domainError('DATABASE_ERROR',
                        'Extension registry maintenance failed.', true)
            end
            if result ~= true then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'Extension registry maintenance was rejected.', true)
            end
            return true, nil
        end, { maximumStatements = 32 })
        return committed == true
    end,
    isOwnerRunning = isExtensionOwnerRunning
})
local observedExtensionOwnerEpochs = {}
local stoppedExtensionOwnerEpochHighWater = {}
local capabilityEvaluator = Capabilities.create({
    maximumRules = 256,
    maximumRoles = 32,
    maximumDelegations = 64,
    maximumScopeKeys = 16,
    evaluateRules = function(permission, rules)
        local evaluateRules, apiError = requireCurrentApi('Permissions', 'evaluateRules')
        if not evaluateRules then return nil, apiError end
        return evaluateRules(permission, rules)
    end
})
local policyEngine = Policy.create({ capabilities = capabilityEvaluator, maximumGates = 16 })
local function checkCoreCharacterPermission(characterId, permission)
    local check, apiError = requireCurrentApi('Permissions', 'check')
    if not check then return nil, apiError end
    local allowed, checkError = check('character:' .. characterId, permission)
    if allowed == true then return true, nil end
    if checkError then return nil, checkError end
    return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
        'The actor character lacks the required global Groups permission.', false, {
            permission = permission
        })
end
local database = createDataPortPersistence({
    dataPort = coreDataPort,
    jsonEncode = encode,
    jsonDecode = decode,
    nextId = function(namespace)
        local nextId, apiError = requireCurrentApi('Ids', 'next')
        if not nextId then return nil, apiError end
        return nextId(namespace)
    end,
    cache = cache,
    registries = registries,
    capabilityEvaluator = capabilityEvaluator,
    policyEngine = policyEngine,
    applicationSchemas = ApplicationSchemas,
    validateOperation = Validation.operation,
    runtimeIndex = runtimeIndex,
    checkCorePermission = checkCoreCharacterPermission,
    applyRegistryMutation = function(mutation)
        return extensionRegistries:apply(mutation)
    end,
    refreshRegistry = function(operation, request, context, response, mutations)
        return extensionRegistries:refresh(
            operation, request, context, response, mutations)
    end,
    observeRegistryOwner = function(owner, epoch)
        if type(owner) ~= 'string' or type(epoch) ~= 'number'
            or math.type(epoch) ~= 'integer' or epoch < 1 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The extension registry owner epoch is invalid.')
        end
        observedExtensionOwnerEpochs[owner] = epoch
        return true, nil
    end,
    isRegistryOwnerEpochActive = function(owner, epoch)
        local stoppedEpoch = stoppedExtensionOwnerEpochHighWater[owner]
        return type(epoch) == 'number'
            and (stoppedEpoch == nil or epoch > stoppedEpoch)
    end
})
local coreCharacters = {
    get = function(characterId)
        local get, apiError = requireCurrentApi('Characters', 'get')
        if not get then return nil, apiError end
        return get(characterId)
    end
}
local coreHooks = {
    run = function(name, value, context)
        local run, apiError = requireCurrentApi('Hooks', 'run')
        if not run then return nil, apiError end
        return run(name, value, context)
    end
}
local coreAudit = {
    append = function(entry)
        local append, apiError = requireCurrentApi('Audit', 'append')
        if not append then return nil, apiError end
        return append(entry)
    end
}
local groupCreationApprovals = createGroupCreationApprovals({
    repository = database,
    permissions = { check = checkCoreCharacterPermission },
    hooks = coreHooks,
    context = function(traceId)
        local epoch = currentApi and currentApi.ownerEpoch
        if type(epoch) ~= 'number' or math.type(epoch) ~= 'integer' or epoch < 1 then
            return nil, Foundation.domainError('CORE_UNAVAILABLE',
                'The Groups resource owner epoch is unavailable.', true)
        end
        return {
            traceId = traceId,
            caller = 'synex_groups',
            callerEpoch = epoch
        }, nil
    end,
    jsonEncode = encode,
    onCommittedEffects = applyCoordinatorEffects,
    errorSink = runtimeErrorSink
})
local groupDeletions = createGroupDeletions({
    repository = database,
    core = {
        plan = function(request)
            local plan, apiError = requireCurrentApi('DomainDeletions', 'plan')
            if not plan then return nil, apiError end
            return plan(request)
        end,
        get = function(planId)
            local get, apiError = requireCurrentApi('DomainDeletions', 'get')
            if not get then return nil, apiError end
            return get(planId)
        end,
        process = function(planId)
            local process, apiError = requireCurrentApi('DomainDeletions', 'process')
            if not process then return nil, apiError end
            return process(planId)
        end
    },
    onLifecycleChanged = function(groupId)
        runtimeIndex:invalidateGroup(groupId)
        return true
    end,
    errorSink = runtimeErrorSink
})
local methods = createService({
    repository = database,
    characters = coreCharacters,
    hooks = coreHooks,
    audit = coreAudit,
    groupCreationApprovals = groupCreationApprovals,
    groupDeletions = groupDeletions,
    runtimeEffects = { apply = applyRuntimeEffect },
    cache = cache,
    jsonEncode = encode,
    errorSink = runtimeErrorSink
})
local outboxDispatcher = createOutboxDispatcher({
    update = function(sql, parameters)
        local result = coreDataPort:writeOrError(sql, parameters, { timeoutMs = 15000 })
        return result.affectedRows
    end,
    query = function(sql, parameters)
        return coreDataPort:readOrError(sql, parameters, {
            maximumRows = 256, maximumResultBytes = 1048576, timeoutMs = 15000
        })
    end,
    jsonDecode = decode
})

local function operationName(contractName)
    return contractName:match('^synex%.groups%.(.+)$'):gsub('%.', '_')
end

local controlProvider = createControlProvider({
    database = database,
    methods = methods,
    query = function(sql, parameters)
        return coreDataPort:readOrError(sql, parameters or {}, {
            maximumRows = 101, maximumResultBytes = 131072, timeoutMs = 5000
        })
    end,
    errorSink = runtimeErrorSink,
    getApi = function() return currentApi end,
})
local function serviceDefinition(binding, registration)
    local serviceMethods, capabilities = {}, {}
    for _, definition in ipairs(definitions) do
        local name = operationName(definition.name)
        local handler = methods[name]
        if type(handler) ~= 'function' then
            error(('synex_groups has no handler for %s'):format(definition.name))
        end
        if definition.network == 'none' then
            serviceMethods[name] = registration:guard(binding, handler)
            capabilities[name] = definition.capability
        end
    end
    return {
        name = 'synex.groups',
        version = Foundation.API_VERSION,
        methods = serviceMethods,
        capabilities = capabilities
    }
end

local function rebuildRuntimeCharacters(api)
    if runtimeRebuildJournal ~= nil then
        return nil, Foundation.domainError('RUNTIME_INDEX_REBUILD_IN_PROGRESS',
            'The Groups runtime index is already rebuilding.', true)
    end
    runtimeRebuildJournal = {}
    local function loadSnapshot()
        local sources = GetPlayers()
        if type(sources) ~= 'table' or #sources > 4096 then
            return nil, Foundation.domainError('RUNTIME_INDEX_CAPACITY_EXCEEDED',
                'The active FiveM player snapshot is invalid or exceeds its bound.', true)
        end
        local contexts, seen = {}, {}
        for _, source in ipairs(sources) do
            local character, characterError = api.Characters.getActive(source)
            if character == false and type(characterError) == 'table' then character = nil end
            if character == nil then
                local code = type(characterError) == 'table' and characterError.code or nil
                if code ~= 'SESSION_NOT_FOUND' and code ~= 'CHARACTER_NOT_ACTIVE' then
                    return nil, characterError or Foundation.domainError(
                        'CORE_UNAVAILABLE', 'An active character could not be resolved.', true)
                end
            else
                local characterId = type(character) == 'table' and character.id or nil
                if not Foundation.isSubjectId(characterId) or seen[characterId] then
                    return nil, Foundation.domainError('RUNTIME_INDEX_INVALID',
                        'The active character snapshot contains an invalid identity.', true)
                end
                seen[characterId] = true
                local context, contextError = loadRuntimeCharacter(characterId)
                if not context then return nil, contextError end
                contexts[#contexts + 1] = context
            end
        end
        return contexts, nil
    end
    local called, contexts, snapshotError = pcall(loadSnapshot)
    if not called then
        snapshotError = type(contexts) == 'table' and contexts
            or Foundation.domainError('RUNTIME_INDEX_REBUILD_FAILED',
                'The active character snapshot could not be rebuilt.', true)
        contexts = nil
    end
    if not contexts then
        runtimeRebuildJournal = nil
        return nil, snapshotError
    end
    local journal = runtimeRebuildJournal
    runtimeRebuildJournal = nil
    local mergedByCharacter = {}
    for _, context in ipairs(contexts) do
        mergedByCharacter[context.characterId] = context
    end
    for characterId, context in pairs(journal) do
        if context == false then
            mergedByCharacter[characterId] = nil
        else
            mergedByCharacter[characterId] = context
        end
    end
    local merged = {}
    for _, context in pairs(mergedByCharacter) do
        merged[#merged + 1] = context
    end
    table.sort(merged, function(left, right)
        return left.characterId < right.characterId
    end)
    local rebuilt, rebuildError = runtimeIndex:rebuild(merged)
    if not rebuilt then return nil, rebuildError end
    return runtimeIndex:snapshot(), nil
end

local function characterLifecycleParticipant(binding, registration)
    local participant = {
        name = 'synex_groups',
        priority = 70,
        required = true,
        prepare = function(context)
            local characterId = context and context.character and context.character.id
            if not Foundation.isSubjectId(characterId) then
                return nil, Foundation.domainError('INVALID_CHARACTER',
                    'Character lifecycle context is invalid.')
            end
            local summary, summaryError = database:getCharacterLifecycleSummary(characterId)
            if not summary then return nil, summaryError end
            local runtimeContext, runtimeError = loadRuntimeCharacter(characterId)
            if not runtimeContext then return nil, runtimeError end
            local replaced, replaceError = replaceRuntimeCharacter(
                characterId, runtimeContext)
            if not replaced then return nil, replaceError end
            return { characterId = characterId, summary = summary }, nil
        end,
        rollback = function(prepared, context)
            local characterId = type(prepared) == 'table' and prepared.characterId
                or context and context.character and context.character.id
            if Foundation.isSubjectId(characterId) then
                removeRuntimeCharacter(characterId)
            end
            return true
        end,
        unload = function(context)
            local characterId = context and context.session and context.session.characterId
            if not Foundation.isSubjectId(characterId) then
                return nil, Foundation.domainError('INVALID_CHARACTER',
                    'Character unload context is invalid.')
            end
            removeRuntimeCharacter(characterId)
            return true
        end,
        deletePreflight = function(context)
            local characterId = context and context.character and context.character.id
            if not Foundation.isSubjectId(characterId) then
                return nil, Foundation.domainError('INVALID_CHARACTER',
                    'Character deletion context is invalid.')
            end
            local summary, summaryError = database:getCharacterLifecycleSummary(characterId)
            if not summary then return nil, summaryError end
            local nextId, apiError = requireCurrentApi('Ids', 'next')
            if not nextId then return nil, apiError end
            local anonymousRef, idError = nextId('anonymous_character')
            if not anonymousRef then return nil, idError end
            return {
                action = 'anonymize',
                metadata = {
                    anonymousRef = anonymousRef,
                    memberships = summary.memberships,
                    primaryMemberships = summary.primaryMemberships
                }
            }
        end,
        deleteCommit = function(context)
            local planId = context and context.planId
            local plan = context and context.plan
            if type(planId) ~= 'string' or #planId < 8 or #planId > 64
                or type(plan) ~= 'table' or not Foundation.isSubjectId(plan.characterId) then
                return nil, Foundation.domainError('INVALID_DELETE_PLAN',
                    'Character deletion plan is invalid.')
            end
            local metadata
            for _, action in ipairs(plan.actions or {}) do
                if action.owner == 'synex_groups' and action.action == 'anonymize' then
                    metadata = action.metadata
                    break
                end
            end
            if type(metadata) ~= 'table' or not Foundation.isPublicId(metadata.anonymousRef) then
                return nil, Foundation.domainError('INVALID_DELETE_PLAN',
                    'Group anonymization metadata is invalid.')
            end
            return database:applyCharacterDeletion(planId, plan.characterId, metadata.anonymousRef)
        end
    }
    for _, name in ipairs({
        'prepare', 'rollback', 'unload', 'deletePreflight', 'deleteCommit'
    }) do
        participant[name] = registration:guard(binding, participant[name])
    end
    return participant
end

SynexGroupsRegisterRuntime({
    Foundation = Foundation,
    CoreBootstrap = CoreBootstrap,
    extensionRegistries = extensionRegistries,
    groupDeletions = groupDeletions,
    characterLifecycleParticipant = characterLifecycleParticipant,
    rebuildRuntimeCharacters = rebuildRuntimeCharacters,
    serviceDefinition = serviceDefinition,
    definitions = definitions,
    methods = methods,
    operationName = operationName,
    scheduleWorkers = scheduleWorkers,
    outboxDispatcher = outboxDispatcher,
    database = database,
    runtimeIndex = runtimeIndex,
    loadRuntimeCharacter = loadRuntimeCharacter,
    groupCreationApprovals = groupCreationApprovals,
    acquireCoreApi = acquireCoreApi,
    setCurrentApi = function(api) currentApi = api end,
    controlProvider = controlProvider,
    runtimeErrorSink = runtimeErrorSink,
    cache = cache,
    observedExtensionOwnerEpochs = observedExtensionOwnerEpochs,
    stoppedExtensionOwnerEpochHighWater = stoppedExtensionOwnerEpochHighWater,
    isExtensionOwnerRunning = isExtensionOwnerRunning
})
return true
end

CoreBootstrap.runWhenReady({
    acquire = acquireCoreApi,
    schedule = SetTimeout,
    onReady = bootstrapRuntime,
    onFailure = function(code)
        runtimeErrorSink({ operation = 'resource_startup', traceId = 'unavailable',
            code = code })
        error(('synex_groups startup failed: %s'):format(code))
    end
})
