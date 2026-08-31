local Foundation = require 'server.foundation'
local createJsonRuntime = require 'server.json_runtime'
local Domain = require('server.domain')(Foundation)
local CoreBootstrap = require('server.core_bootstrap')(Foundation)
local createOperatorAdapter = require('server.operator_adapter')(Foundation, Domain)
local createControlProvider = require('server.control_provider')(Foundation)
local createOutboxDispatcher = require('server.outbox')(Foundation)
local createFinancialRetention = require('server.retention')(Foundation)
local createLegacyService = require('server.service')(Foundation)
local createServiceV2 = require('server.service_v2')(Foundation, Domain)
local createLifecycle = require('server.lifecycle')(Foundation)
local persistenceModules = {
    accounts = require 'server.persistence.accounts',
    ledger = require 'server.persistence.ledger',
    holds = require 'server.persistence.holds',
    access = require 'server.persistence.access',
    integrity = require 'server.persistence.integrity',
    engineShared = require 'server.persistence.engine_shared',
    accountsV2 = require 'server.persistence.accounts_v2',
    transactions = require 'server.persistence.transactions',
    transactionReads = require 'server.persistence.transaction_reads',
    holdsV2 = require 'server.persistence.holds_v2',
    accessV2 = require 'server.persistence.access_v2',
    restrictionsV2 = require 'server.persistence.restrictions_v2',
    integrityBehavior = require 'server.persistence.integrity_behavior',
    engine = require 'server.persistence.integrity_v2',
    integrityControl = require 'server.persistence.integrity_control',
    observability = require 'server.persistence.observability',
    lifecycle = require 'server.persistence.lifecycle',
}
local createOxmysqlPort = require('server.persistence')(Foundation, persistenceModules)
local loadContractDefinitions = require('server.contracts')(Foundation)

local module = {
    Foundation = Foundation,
    Domain = Domain,
    CoreBootstrap = CoreBootstrap,
    createService = createLegacyService,
    createServiceV2 = createServiceV2,
    createOxmysqlPort = createOxmysqlPort,
    createOutboxDispatcher = createOutboxDispatcher,
    createFinancialRetention = createFinancialRetention,
    createJsonRuntime = createJsonRuntime,
    createLifecycle = createLifecycle,
    createControlProvider = createControlProvider,
    contractDefinitions = loadContractDefinitions,
}

if rawget(_G, 'SYNEX_TEST_MODE') == true then return module end

local RESOURCE = 'synex_accounts'
local SERVICE = 'synex.accounts'
local runtimeJson = createJsonRuntime(json)
local encode = runtimeJson.encode
local decode = runtimeJson.decode

local function runtimeErrorSink(event)
    local candidate = type(event) == 'table' and event or {}
    local encoded = encode({
        level = 'error',
        event = 'accounts_runtime_error',
        resource = RESOURCE,
        operation = type(candidate.operation) == 'string'
            and candidate.operation:sub(1, 96) or 'unknown',
        code = type(candidate.code) == 'string'
            and candidate.code:sub(1, 64) or 'DATABASE_ERROR',
        traceId = type(candidate.traceId) == 'string'
            and candidate.traceId:sub(1, 64) or 'unavailable',
    })
    print(encoded)
end

local rawCatalog = LoadResourceFile(GetCurrentResourceName(), 'accounts.contracts.json')
local definitions, catalogError = loadContractDefinitions(rawCatalog, decode)
if not definitions then
    error(('synex_accounts contract catalog failed validation: %s'):format(
        catalogError and catalogError.message or 'unknown error'))
end

local currentApi
local coreMetrics = {}
local database = createOxmysqlPort({
    jsonEncode = encode,
    jsonDecode = decode,
    random = math.random,
    domain = Domain,
    errorSink = runtimeErrorSink,
    metrics = coreMetrics,
    wait = Wait,
})

local function withDatabaseTransaction(handler)
    if not Foundation.isCallable(handler)
        or not Foundation.isCallable(MySQL.startTransaction) then
        return nil, Foundation.domainError('TRANSACTION_UNAVAILABLE',
            'Interactive database transactions are unavailable.', true)
    end
    local invoked, committed = pcall(MySQL.startTransaction, handler)
    if not invoked or committed ~= true then
        return nil, Foundation.domainError('WRITE_CONFLICT',
            'The account transaction could not be committed.', true)
    end
    return true, nil
end

local function requireCurrentApi(section, method)
    local api = currentApi
    if not api or type(api[section]) ~= 'table'
        or not Foundation.isCallable(api[section][method]) then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            ('Synex Core %s.%s is unavailable.'):format(section, method), true)
    end
    return api[section][method], nil
end

local coreHooks = {
    run = function(name, value, context)
        local run, apiError = requireCurrentApi('Hooks', 'run')
        if not run then return nil, apiError end
        return run(name, value, context)
    end,
}
local coreAudit = {
    append = function(entry)
        local append, apiError = requireCurrentApi('Audit', 'append')
        if not append then return nil, apiError end
        return append(entry)
    end,
}
local coreCapabilities = {
    checkResource = function(resourceName, capability, operation)
        local check, apiError = requireCurrentApi('Capabilities', 'checkResource')
        if not check then return nil, apiError end
        local called, allowed, capabilityError = pcall(function()
            return check(resourceName, capability, operation)
        end)
        if not called then
            return nil, Foundation.domainError('CORE_UNAVAILABLE',
                'The Core capability preflight could not be completed.', true)
        end
        return allowed, capabilityError
    end,
}
for _, method in ipairs({ 'increment', 'gauge', 'observe' }) do
    local methodName = method
    coreMetrics[methodName] = function(name, labels, value)
        local writer = currentApi and currentApi.Metrics
            and currentApi.Metrics[methodName] or nil
        if not Foundation.isCallable(writer) then return false end
        local called, accepted = pcall(writer, name, labels, value)
        return called and accepted == true
    end
end

local methods = createServiceV2({
    db = database,
    jsonEncode = encode,
    jsonDecode = decode,
    hooks = coreHooks,
    audit = coreAudit,
    checkResourceCapability = coreCapabilities.checkResource,
    errorSink = runtimeErrorSink,
})
local lifecycle = createLifecycle({ repository = database, random = math.random })
local outboxDispatcher = createOutboxDispatcher({
    update = function(sql, parameters)
        return MySQL.update.await(sql, parameters or {})
    end,
    query = function(sql, parameters)
        return MySQL.query.await(sql, parameters or {})
    end,
    jsonDecode = decode,
    random = math.random,
    recordAttempts = true,
    withTransaction = withDatabaseTransaction,
})

local financialOperations = {
    transfer = true, transfer_v2 = true, debit = true, credit = true,
    mint = true, mint_v2 = true, burn = true, burn_v2 = true, post = true,
    hold_capture = true, capture_hold = true, transaction_reverse = true,
    reverse = true, transaction_refund = true,
}

local function monotonicMilliseconds()
    local called, value = pcall(GetGameTimer)
    if called and type(value) == 'number' then return value end
    return math.floor(os.clock() * 1000)
end

local economySecurityCodes = {
    PRINCIPAL_SPOOFED = { severity = 'HIGH', confidence = 0.98,
        key = 'principal-spoofed' },
    ACCOUNT_ACCESS_DENIED = { severity = 'MEDIUM', confidence = 0.90,
        key = 'access-denied' },
    ACCESS_DENIED = { severity = 'MEDIUM', confidence = 0.90,
        key = 'access-denied' },
    REASON_CODE_NOT_OWNED = { severity = 'MEDIUM', confidence = 0.92,
        key = 'reason-namespace-denied' },
    IDEMPOTENCY_CONFLICT = { severity = 'MEDIUM', confidence = 0.94,
        key = 'idempotency-conflict' },
    OUTBOX_RETRY_IDEMPOTENCY_CONFLICT = { severity = 'MEDIUM', confidence = 0.94,
        key = 'idempotency-conflict' },
    OPERATION_NOT_ALLOWED = { severity = 'LOW', confidence = 0.72,
        key = 'operation-forbidden' },
}

local function reportEconomyDenial(operation, operationError, context)
    local code = type(operationError) == 'table' and operationError.code or nil
    local policy = economySecurityCodes[code]
    local api = currentApi
    local call = type(api) == 'table' and type(api.Services) == 'table'
        and api.Services.call or nil
    if not policy or not Foundation.isCallable(call) then return false end
    local session = type(context) == 'table' and context.session or nil
    local subject
    if type(session) == 'table' and type(session.id) == 'string'
        and type(session.sourceGeneration) == 'number'
        and type(context.source) == 'number' then
        subject = {
            sessionId = session.id,
            source = context.source,
            sourceGeneration = session.sourceGeneration,
            userId = session.userId,
            characterId = session.characterId,
        }
    else
        local caller = type(context) == 'table'
            and (context.caller or context.callerResource) or nil
        subject = { resourceName = type(caller) == 'string' and caller or RESOURCE }
    end
    local ok = pcall(call, 'synex.security', '^1.0.0', 'reportSignal', {
        namespace = 'synex.accounts',
        category = 'economy',
        detector = 'synex.accounts.domain',
        code = code,
        subject = subject,
        severity = policy.severity,
        confidence = policy.confidence,
        evidenceClass = 'DOMAIN_AUTHORITATIVE',
        correlationKey = 'economy:' .. policy.key,
        traceId = type(context) == 'table' and context.traceId or nil,
        summary = 'Accounts authority rejected a security-relevant financial operation.',
        evidenceJson = encode({ operation = tostring(operation):sub(1, 64) }),
    }, {
        traceId = type(context) == 'table' and context.traceId or nil,
        timeoutMs = 1000,
    })
    return ok
end

local function instrumentedHandler(operation, handler)
    return function(request, context)
        local startedAt = monotonicMilliseconds()
        local value, operationError = handler(request, context)
        local duration = math.max(0, monotonicMilliseconds() - startedAt)
        local outcome = value ~= nil and operationError == nil and 'success' or 'failure'
        coreMetrics.increment('synex_accounts_operations_total', {
            operation = operation, outcome = outcome,
        })
        coreMetrics.observe('synex_accounts_operation_duration_ms', {
            operation = operation,
        }, duration)
        if financialOperations[operation] then
            coreMetrics.increment('synex_accounts_transactions_total', {
                operation = operation, outcome = outcome,
            })
            coreMetrics.observe('synex_accounts_transaction_duration_ms', {
                operation = operation,
            }, duration)
            if outcome == 'failure' then
                coreMetrics.increment('synex_accounts_transaction_failures_total', {
                    operation = operation,
                })
            end
        end
        local code = type(operationError) == 'table' and operationError.code or nil
        if code == 'ACCOUNT_ACCESS_DENIED' or code == 'ACCESS_DENIED'
            or code == 'REASON_CODE_NOT_OWNED' then
            coreMetrics.increment('synex_accounts_access_denials_total', {
                operation = operation,
            })
        end
        if outcome == 'failure' then
            -- Accounts has already rejected the operation. Security reporting is
            -- deliberately fail-open and can never authorize or roll back money.
            reportEconomyDenial(operation, operationError, context)
        end
        if value and (operation == 'integrity_reconcile'
            or operation == 'run_reconciliation') then
            coreMetrics.gauge('synex_accounts_reconciliation_findings', {},
                tonumber(value.finding_count) or 0)
        end
        return value, operationError
    end
end

local function operationName(contractName)
    local suffix = type(contractName) == 'string'
        and contractName:match('^synex%.accounts%.(.+)$') or nil
    return suffix and suffix:gsub('%.', '_') or nil
end

local function acquireCoreApi()
    local called, api, apiError = pcall(function()
        return exports.synex_core:GetAPI(Foundation.API_RANGE)
    end)
    if not called then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'synex_accounts could not reach the Synex API export.', true)
    end
    if not api then
        return nil, apiError or Foundation.domainError('CORE_UNAVAILABLE',
            'synex_accounts could not acquire the Synex API.', true)
    end
    if not CoreBootstrap.validateApi(api) then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'synex_accounts requires the Core runtime, capability, event, scheduler, lifecycle, deletion, hook, audit, service, and RPC APIs.', true)
    end
    return api, nil
end

local function retentionPolicy(api)
    local value, runtimeError = api.Runtime.getRetentionPolicy()
    if not value then return nil, runtimeError end
    if type(value) ~= 'table' or not Foundation.jsonContainerKind(value)
        or type(value.workerIntervalMs) ~= 'number'
        or math.type(value.workerIntervalMs) ~= 'integer'
        or value.workerIntervalMs < 60000 or value.workerIntervalMs > 86400000
        or type(value.batchSize) ~= 'number'
        or math.type(value.batchSize) ~= 'integer'
        or value.batchSize < 1 or value.batchSize > 1000 then
        return nil, Foundation.domainError('INVALID_RETENTION_POLICY',
            'The Core financial retention policy is invalid.')
    end
    local financial = value.financial
    if type(financial) ~= 'table' or not Foundation.jsonContainerKind(financial)
        or (financial.mode ~= 'retain_forever' and financial.mode ~= 'archive')
        or type(financial.archiveAfterDays) ~= 'number'
        or math.type(financial.archiveAfterDays) ~= 'integer'
        or financial.archiveAfterDays < 1 or financial.archiveAfterDays > 36500 then
        return nil, Foundation.domainError('INVALID_RETENTION_POLICY',
            'The Core financial retention policy is invalid.')
    end
    for key in pairs(financial) do
        if key ~= 'mode' and key ~= 'archiveAfterDays' then
            return nil, Foundation.domainError('INVALID_RETENTION_POLICY',
                'The Core financial retention policy contains an unknown property.')
        end
    end
    return {
        mode = financial.mode,
        archiveAfterDays = financial.archiveAfterDays,
        workerIntervalMs = value.workerIntervalMs,
        batchSize = value.batchSize,
    }, nil
end

local coreRegistration
local operatorMethods = createOperatorAdapter({
    database = database,
    outboxDispatcher = outboxDispatcher,
    coreAudit = coreAudit,
    runtimeErrorSink = runtimeErrorSink,
})
local controlProvider = createControlProvider({
    database = database,
    operatorMethods = operatorMethods,
    query = function(sql, parameters) return MySQL.query.await(sql, parameters or {}) end,
    errorSink = runtimeErrorSink,
    getApi = function() return currentApi end,
})

local function resolveMethod(methodName)
    return methods[methodName] or operatorMethods[methodName]
end

local function serviceDefinition(binding)
    local serviceMethods, capabilities = {}, {}
    for _, definition in ipairs(definitions) do
        local methodName = operationName(definition.name)
        local handler = methodName and resolveMethod(methodName)
        if not Foundation.isCallable(handler) then
            error(('synex_accounts has no handler for %s'):format(definition.name))
        end
        serviceMethods[methodName] = coreRegistration:guard(
            binding, instrumentedHandler(methodName, handler))
        capabilities[methodName] = definition.capability
    end
    serviceMethods.get_control_summary = coreRegistration:guard(
        binding, instrumentedHandler('get_control_summary', methods.get_control_summary))
    capabilities.get_control_summary = 'synex.accounts.integrity.read'
    for methodName, handler in pairs(operatorMethods) do
        serviceMethods[methodName] = coreRegistration:guard(
            binding, instrumentedHandler(methodName, handler))
        capabilities[methodName] = capabilities[methodName]
            or (methodName == 'outbox_retry' and 'synex.accounts.outbox.retry'
                or 'synex.accounts.integrity.read')
    end
    return {
        name = SERVICE,
        version = Foundation.API_VERSION,
        stability = 'experimental',
        methods = serviceMethods,
        capabilities = capabilities,
    }
end

local function guardedCharacterParticipant(binding)
    local participant = lifecycle:characterParticipant()
    for _, methodName in ipairs({
        'prepare', 'rollback', 'unload', 'deletePreflight', 'deleteCommit'
    }) do
        participant[methodName] = coreRegistration:guard(
            binding, participant[methodName])
    end
    return participant
end

local function guardedDeletionProvider(binding)
    local provider = lifecycle:groupProvider()
    provider.preflight = coreRegistration:guard(binding, provider.preflight)
    provider.execute = coreRegistration:guard(binding, provider.execute)
    return provider
end

local function workerFailure(operation, runtimeError)
    runtimeErrorSink({
        operation = operation,
        code = type(runtimeError) == 'table' and runtimeError.code
            or 'WORKER_FAILED',
        traceId = 'unavailable',
    })
end

local function scheduleWorkers(api, binding, tokens)
    if not coreRegistration:isCurrent(binding) then
        return nil, Foundation.domainError('STALE_RESOURCE',
            'The Accounts worker generation is stale.', true)
    end
    local policy, policyError = retentionPolicy(api)
    if not policy then return nil, policyError end
    local archive
    if policy.mode == 'archive' then
        archive, policyError = createFinancialRetention({
            update = function(sql, parameters)
                return MySQL.update.await(sql, parameters or {})
            end,
            withTransaction = withDatabaseTransaction,
            policy = {
                mode = policy.mode,
                archiveAfterDays = policy.archiveAfterDays,
                batchSize = policy.batchSize,
            },
        })
        if not archive then return nil, policyError end
    end

    local workers = {
        {
            name = 'synex_accounts.outbox_dispatcher',
            delay = 1000,
            handler = function()
                local claimToken, claimError = api.Ids.next('outbox_claim')
                if not claimToken then return nil, claimError end
                local report, dispatchError = outboxDispatcher:dispatchBatch(claimToken,
                    function(topic, payload, options)
                        return api.Events.publishOutbox(topic, payload, {
                            traceId = options.traceId,
                            eventId = options.eventId,
                            aggregateId = options.aggregateId,
                            schemaVersion = options.schemaVersion,
                        })
                    end, { maximum = 25 })
                if report then
                    coreMetrics.increment('synex_accounts_outbox_published_total', {},
                        report.published or 0)
                    coreMetrics.increment('synex_accounts_outbox_retries_total', {},
                        report.retried or 0)
                    coreMetrics.increment('synex_accounts_outbox_dead_total', {},
                        report.dead or 0)
                end
                return report, dispatchError
            end,
        },
        {
            name = 'synex_accounts.hold_expiry',
            delay = 5000,
            handler = function()
                local report, expiryError = database:expireHolds(25)
                if report then
                    coreMetrics.increment('synex_accounts_holds_expired_total', {},
                        report.expired or 0)
                end
                return report, expiryError
            end,
        },
        {
            name = 'synex_accounts.restriction_expiry',
            delay = 15000,
            handler = function() return database:expireRestrictions(50) end,
        },
        {
            name = 'synex_accounts.operational_metrics',
            delay = 15000,
            handler = function()
                local snapshot, snapshotError = database:getOperationalMetrics()
                if not snapshot then return nil, snapshotError end
                for field, metricName in pairs({
                    holds_active = 'synex_accounts_holds_active',
                    holds_expired = 'synex_accounts_holds_expired_pending',
                    outbox_pending = 'synex_accounts_outbox_pending',
                    outbox_publishing = 'synex_accounts_outbox_publishing',
                    outbox_dead = 'synex_accounts_outbox_dead',
                    reconciliation_findings = 'synex_accounts_reconciliation_findings',
                }) do
                    local value = tonumber(snapshot[field])
                    if not value or math.type(value) ~= 'integer' or value < 0
                        or value > Foundation.MAX_MINOR then
                        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                            'An Accounts operational metric is invalid.')
                    end
                    coreMetrics.gauge(metricName, {}, value)
                end
                return snapshot, nil
            end,
        },
    }
    if archive then
        workers[#workers + 1] = {
            name = 'synex_accounts.financial_retention',
            delay = policy.workerIntervalMs,
            handler = function() return archive:archiveBatch() end,
        }
    end

    local newlyScheduled = {}
    local function cancelNew(runtimeError)
        for index = #newlyScheduled, 1, -1 do
            local item = newlyScheduled[index]
            pcall(api.Scheduler.cancel, item.token)
            tokens[item.name] = nil
        end
        return nil, runtimeError
    end
    for _, worker in ipairs(workers) do
        if not tokens[worker.name] then
            local selected = worker
            local token, scheduleError = api.Scheduler.every(selected.delay, function()
                if not coreRegistration:isCurrent(binding)
                    or not coreRegistration:isReady(binding) then
                    return true, nil
                end
                local called, report, runtimeError = pcall(selected.handler)
                if not called then
                    workerFailure(selected.name, report)
                    return nil, Foundation.domainError('WORKER_FAILED',
                        'An Accounts worker raised an exception.', true)
                end
                if not report then workerFailure(selected.name, runtimeError) end
                return report, runtimeError
            end, { name = selected.name })
            if not token then
                return cancelNew(scheduleError or Foundation.domainError(
                    'WORKER_REGISTRATION_FAILED',
                    'An Accounts worker could not be registered.', true))
            end
            tokens[selected.name] = token
            newlyScheduled[#newlyScheduled + 1] = {
                name = selected.name,
                token = token,
            }
        end
        if not coreRegistration:isCurrent(binding) then
            return cancelNew(Foundation.domainError('STALE_RESOURCE',
                'The Accounts worker generation is stale.', true))
        end
    end
    return true, nil
end

local coreRebindGeneration = 1
coreRegistration = CoreBootstrap.createRegistration({
    serviceName = SERVICE,
    serviceVersion = Foundation.API_VERSION,
    contracts = definitions,
    isGenerationCurrent = function(generation)
        return generation == coreRebindGeneration
    end,
    serviceDefinition = serviceDefinition,
    contractHandler = function(definition, binding)
        local methodName = operationName(definition.name)
        local handler = methodName and resolveMethod(methodName)
        if not Foundation.isCallable(handler) then
            error(('synex_accounts has no handler for %s'):format(definition.name))
        end
        return coreRegistration:guard(
            binding, instrumentedHandler(methodName, handler))
    end,
    characterParticipant = guardedCharacterParticipant,
    deletionProvider = guardedDeletionProvider,
    scheduleWorkers = scheduleWorkers,
})

local function startCoreBinding(generation, operation)
    CoreBootstrap.runWhenReady({
        acquire = acquireCoreApi,
        schedule = SetTimeout,
        isCurrent = function() return generation == coreRebindGeneration end,
        onReady = function(api)
            if generation ~= coreRebindGeneration then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'The Accounts Core binding generation is stale.', true)
            end
            currentApi = api
            local bound, bindingError = coreRegistration:bind(api, generation)
            if not bound then return nil, bindingError end
            local _, providerError = controlProvider:register(api)
            if providerError then
                runtimeErrorSink({ operation = 'control_provider_register',
                    code = providerError.code or 'CONTROL_PROVIDER_UNAVAILABLE',
                    traceId = 'unavailable' })
            end
            return true
        end,
        onFailure = function(code, runtimeError)
            runtimeErrorSink({
                operation = operation,
                code = type(runtimeError) == 'table' and runtimeError.code or code,
                traceId = 'unavailable',
            })
        end,
        failureCode = 'CORE_BINDING_FAILED',
        timeoutCode = 'CORE_BINDING_TIMEOUT',
        recoveryDelayMs = 5000,
    })
end

startCoreBinding(coreRebindGeneration, 'resource_startup')

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'synex_core' then return end
    coreRebindGeneration = coreRebindGeneration + 1
    currentApi = nil
    coreRegistration:invalidate()
    startCoreBinding(coreRebindGeneration, 'core_restart_registration')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == 'synex_core' then
        coreRebindGeneration = coreRebindGeneration + 1
        currentApi = nil
        coreRegistration:invalidate()
    elseif resourceName == RESOURCE then
        coreRegistration:invalidate()
    end
end)

return true
