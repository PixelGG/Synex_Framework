local Foundation = require 'server.foundation'
local createOutboxDispatcher = require('server.outbox')(Foundation)
local createFinancialRetention = require('server.retention')(Foundation)
local createService = require('server.service')(Foundation)
local persistenceModules = {
    accounts = require 'server.persistence.accounts',
    ledger = require 'server.persistence.ledger',
    holds = require 'server.persistence.holds',
    access = require 'server.persistence.access',
    integrity = require 'server.persistence.integrity'
}
local createOxmysqlPort = require('server.persistence')(Foundation, persistenceModules)
local contractDefinitions = require('server.contracts')(Foundation)

local module = {
    createService = createService,
    createOxmysqlPort = createOxmysqlPort,
    createOutboxDispatcher = createOutboxDispatcher,
    createFinancialRetention = createFinancialRetention,
    contractDefinitions = contractDefinitions
}

if rawget(_G, 'SYNEX_TEST_MODE') == true then return module end

local function runtimeErrorSink(event)
    print(json.encode({
        level = 'error',
        event = 'unexpected_handler_error',
        resource = 'synex_accounts',
        operation = event.operation,
        traceId = event.traceId
    }))
end

local database = createOxmysqlPort({
    jsonEncode = function(value) return json.encode(value) end,
    jsonDecode = function(value) return json.decode(value) end,
    random = math.random
})
local methods = createService({
    db = database,
    jsonEncode = function(value) return json.encode(value) end,
    jsonDecode = function(value) return json.decode(value) end,
    errorSink = runtimeErrorSink
})
local outboxDispatcher = createOutboxDispatcher({
    update = function(sql, parameters) return MySQL.update.await(sql, parameters) end,
    query = function(sql, parameters) return MySQL.query.await(sql, parameters) end,
    jsonDecode = function(value) return json.decode(value) end
})

local function registerCoreBindings()
local api, apiError = exports.synex_core:GetAPI(Foundation.API_RANGE)
if not api then error(('synex_accounts could not acquire the Synex API: %s'):format(apiError and apiError.message or 'unknown error')) end

if not api.Runtime or not Foundation.isCallable(api.Runtime.getRetentionPolicy) then
    error('synex_accounts requires the Core retention policy API')
end
local retentionPolicy, retentionPolicyError = api.Runtime.getRetentionPolicy()
if not retentionPolicy then
    error(('synex_accounts could not read the retention policy: %s'):format(
        retentionPolicyError and retentionPolicyError.message or 'unknown error'))
end
local retentionModes = { retain_forever = true, archive = true }
local topLevelKeys = { audit = true, financial = true, workerIntervalMs = true, batchSize = true }
if type(retentionPolicy) ~= 'table' or getmetatable(retentionPolicy) ~= nil then
    error('synex_accounts received an invalid retention policy')
end
for key in pairs(retentionPolicy) do
    if type(key) ~= 'string' or not topLevelKeys[key] then
        error('synex_accounts received an invalid retention policy')
    end
end
if type(retentionPolicy.workerIntervalMs) ~= 'number'
    or math.type(retentionPolicy.workerIntervalMs) ~= 'integer'
    or retentionPolicy.workerIntervalMs < 60000 or retentionPolicy.workerIntervalMs > 86400000
    or type(retentionPolicy.batchSize) ~= 'number' or math.type(retentionPolicy.batchSize) ~= 'integer'
    or retentionPolicy.batchSize < 1 or retentionPolicy.batchSize > 1000 then
    error('synex_accounts received an invalid retention policy')
end
for _, name in ipairs({ 'audit', 'financial' }) do
    local policy = retentionPolicy[name]
    if type(policy) ~= 'table' or getmetatable(policy) ~= nil
        or not retentionModes[policy.mode]
        or type(policy.archiveAfterDays) ~= 'number'
        or math.type(policy.archiveAfterDays) ~= 'integer'
        or policy.archiveAfterDays < 1 or policy.archiveAfterDays > 36500 then
        error('synex_accounts received an invalid retention policy')
    end
    for key in pairs(policy) do
        if key ~= 'mode' and key ~= 'archiveAfterDays' then
            error('synex_accounts received an invalid retention policy')
        end
    end
end

local financialRetention = nil
if retentionPolicy.financial.mode == 'archive' then
    local retentionError
    financialRetention, retentionError = createFinancialRetention({
        update = function(sql, parameters) return MySQL.update.await(sql, parameters) end,
        policy = {
            mode = retentionPolicy.financial.mode,
            archiveAfterDays = retentionPolicy.financial.archiveAfterDays,
            batchSize = retentionPolicy.batchSize
        }
    })
    if not financialRetention then
        error(('synex_accounts could not configure financial retention: %s'):format(
            retentionError and retentionError.message or 'unknown error'))
    end
end

local _, serviceError = api.Services.provide({
    name = 'synex.accounts',
    version = Foundation.API_VERSION,
    methods = {
        get_snapshot = methods.get_snapshot,
        list_owner_accounts = methods.list_owner_accounts,
        get_hold = methods.get_hold,
        get_access = methods.get_access,
        get_integrity = methods.get_integrity,
        get_control_summary = methods.get_control_summary
    },
    capabilities = {
        get_snapshot = 'synex.accounts.read',
        list_owner_accounts = 'synex.accounts.read',
        get_hold = 'synex.accounts.read',
        get_access = 'synex.accounts.access.read',
        get_integrity = 'synex.accounts.integrity.read',
        get_control_summary = 'synex.accounts.integrity.read'
    }
})
if serviceError then error(('synex_accounts service registration failed: %s'):format(serviceError.message)) end

local _, participantError = api.Characters.registerLifecycleParticipant({
    name = 'synex_accounts',
    priority = 80,
    required = true,
    prepare = function(context)
        local characterId = context and context.character and context.character.id
        if not Foundation.isSubjectId(characterId) then
            return nil, Foundation.domainError('INVALID_CHARACTER', 'Character lifecycle context is invalid.')
        end
        return database:getCharacterLifecycleSummary(characterId)
    end,
    rollback = function()
        return true
    end,
    unload = function()
        return true
    end,
    deletePreflight = function(context)
        local characterId = context and context.character and context.character.id
        if not Foundation.isSubjectId(characterId) then
            return nil, Foundation.domainError('INVALID_CHARACTER', 'Character deletion context is invalid.')
        end
        local summary, summaryError = database:getCharacterLifecycleSummary(characterId)
        if not summary then return nil, summaryError end
        if summary.nonterminalHolds > 0 then
            return {
                action = 'block',
                code = 'CHARACTER_ACCOUNTS_HAVE_HOLDS',
                message = 'Release or capture all character account holds before deletion.',
            }
        end
        return {
            action = 'anonymize',
            metadata = {
                anonymousRef = Foundation.uuidV4(math.random),
                accounts = summary.accounts,
                grants = summary.activeGrants,
                ledgerHistory = 'retain',
            },
        }
    end,
    deleteCommit = function(context)
        local planId = context and context.planId
        local plan = context and context.plan
        if type(planId) ~= 'string' or #planId < 8 or #planId > 64 or type(plan) ~= 'table'
            or not Foundation.isSubjectId(plan.characterId) then
            return nil, Foundation.domainError('INVALID_DELETE_PLAN', 'Character deletion plan is invalid.')
        end
        local metadata
        for _, action in ipairs(plan.actions or {}) do
            if action.owner == 'synex_accounts' and action.action == 'anonymize' then
                metadata = action.metadata
                break
            end
        end
        if type(metadata) ~= 'table' or not Foundation.isUuid(metadata.anonymousRef) then
            return nil, Foundation.domainError('INVALID_DELETE_PLAN', 'Account anonymization metadata is invalid.')
        end
        return database:applyCharacterDeletion(planId, plan.characterId, metadata.anonymousRef)
    end,
})
if participantError then
    error(('synex_accounts character lifecycle registration failed: %s'):format(participantError.message))
end

local definitions = contractDefinitions()
for _, definition in ipairs(definitions) do
    local methodName = definition.name:match('^synex%.accounts%.(.+)$')
    local _, registrationError = api.RPC.registerServer(definition, methods[methodName])
    if registrationError then
        error(('synex_accounts contract registration failed for %s: %s'):format(definition.name, registrationError.message))
    end
end

if not api.Ids or not Foundation.isCallable(api.Ids.next)
    or not api.Events or not Foundation.isCallable(api.Events.publishOutbox)
    or not api.Scheduler or not Foundation.isCallable(api.Scheduler.every) then
    error('synex_accounts requires the Core ID, event, and scheduler APIs')
end
local scheduled, scheduleError = api.Scheduler.every(1000, function()
    local claimToken, claimError = api.Ids.next('outbox_claim')
    if not claimToken then return nil, claimError end
    local report, dispatchError = outboxDispatcher:dispatchBatch(claimToken, function(topic, payload, options)
        return api.Events.publishOutbox(topic, payload, {
            traceId = options.traceId,
            eventId = options.eventId,
            aggregateId = options.aggregateId,
            schemaVersion = options.schemaVersion
        })
    end, { maximum = 25 })
    if not report then return nil, dispatchError end
    if report.recovered > 0 or report.retried > 0 or report.dead > 0 then
        print(json.encode({
            level = report.dead > 0 and 'error' or report.retried > 0 and 'warn' or 'info',
            event = 'outbox_dispatch_result',
            resource = 'synex_accounts',
            recovered = report.recovered,
            claimed = report.claimed,
            published = report.published,
            retried = report.retried,
            dead = report.dead,
            failures = report.failures
        }))
    end
    return report, nil
end, { name = 'synex_accounts.outbox_dispatcher' })
if not scheduled then
    error(('synex_accounts outbox worker registration failed: %s'):format(
        scheduleError and scheduleError.message or 'unknown error'))
end
if financialRetention then
    local retentionScheduled, retentionScheduleError = api.Scheduler.every(
        retentionPolicy.workerIntervalMs, function()
            local report, archiveError = financialRetention:archiveBatch()
            if not report then return nil, archiveError end
            print(json.encode({
                level = 'info',
                event = 'financial_archive_result',
                resource = 'synex_accounts',
                archiveAfterDays = report.archiveAfterDays,
                batchSize = report.batchSize,
                archived = report.archived,
                sourceRowsDeleted = report.sourceRowsDeleted,
                batchExhausted = report.batchExhausted
            }))
            return report, nil
        end, { name = 'synex_accounts.retention.financial_archive' })
    if not retentionScheduled then
        error(('synex_accounts financial retention worker registration failed: %s'):format(
            retentionScheduleError and retentionScheduleError.message or 'unknown error'))
    end
end
end

registerCoreBindings()

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'synex_core' then return end
    local ok = pcall(registerCoreBindings)
    if not ok then runtimeErrorSink({ operation = 'core_restart_registration', traceId = 'unavailable' }) end
end)
