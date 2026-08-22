local Foundation = require 'server.foundation'
local createOutboxDispatcher = require('server.outbox')(Foundation)
local createService = require('server.service')(Foundation)
local persistenceModules = {
    observability = require 'server.persistence.observability'
}
local createOxmysqlPort = require('server.persistence')(Foundation, persistenceModules)
local contractDefinitions = require('server.contracts')(Foundation)

local module = {
    createService = createService,
    createOxmysqlPort = createOxmysqlPort,
    createOutboxDispatcher = createOutboxDispatcher,
    contractDefinitions = contractDefinitions,
    evaluateCapabilityRules = Foundation.evaluateCapabilityRules
}

if rawget(_G, 'SYNEX_TEST_MODE') == true then return module end

local function runtimeErrorSink(event)
    print(json.encode({
        level = 'error',
        event = 'unexpected_handler_error',
        resource = 'synex_groups',
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
if not api then error(('synex_groups could not acquire the Synex API: %s'):format(apiError and apiError.message or 'unknown error')) end

local _, serviceError = api.Services.provide({
    name = 'synex.groups',
    version = Foundation.API_VERSION,
    methods = {
        get = methods.get,
        get_read_model = methods.get_read_model,
        list_subject_memberships = methods.list_subject_memberships,
        check_capability = methods.check_capability,
        get_control_summary = methods.get_control_summary
    },
    capabilities = {
        get = 'synex.groups.read',
        get_read_model = 'synex.groups.read',
        list_subject_memberships = 'synex.groups.read',
        check_capability = 'synex.groups.read',
        get_control_summary = 'synex.groups.read'
    }
})
if serviceError then error(('synex_groups service registration failed: %s'):format(serviceError.message)) end

local _, participantError = api.Characters.registerLifecycleParticipant({
    name = 'synex_groups',
    priority = 70,
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
        return {
            action = 'anonymize',
            metadata = {
                anonymousRef = Foundation.uuidV4(math.random),
                memberships = summary.memberships,
                primaryMemberships = summary.primaryMemberships,
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
            if action.owner == 'synex_groups' and action.action == 'anonymize' then
                metadata = action.metadata
                break
            end
        end
        if type(metadata) ~= 'table' or not Foundation.isUuid(metadata.anonymousRef) then
            return nil, Foundation.domainError('INVALID_DELETE_PLAN', 'Group anonymization metadata is invalid.')
        end
        return database:applyCharacterDeletion(planId, plan.characterId, metadata.anonymousRef)
    end,
})
if participantError then
    error(('synex_groups character lifecycle registration failed: %s'):format(participantError.message))
end

local definitions = contractDefinitions()
for _, definition in ipairs(definitions) do
    local methodName = definition.name:match('^synex%.groups%.(.+)$')
    local _, registrationError = api.RPC.registerServer(definition, methods[methodName])
    if registrationError then
        error(('synex_groups contract registration failed for %s: %s'):format(definition.name, registrationError.message))
    end
end

if not api.Ids or type(api.Ids.next) ~= 'function'
    or not api.Events or type(api.Events.publishOutbox) ~= 'function'
    or not api.Scheduler or type(api.Scheduler.every) ~= 'function' then
    error('synex_groups requires the Core ID, event, and scheduler APIs')
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
            resource = 'synex_groups',
            recovered = report.recovered,
            claimed = report.claimed,
            published = report.published,
            retried = report.retried,
            dead = report.dead,
            failures = report.failures
        }))
    end
    return report, nil
end, { name = 'synex_groups.outbox_dispatcher' })
if not scheduled then
    error(('synex_groups outbox worker registration failed: %s'):format(
        scheduleError and scheduleError.message or 'unknown error'))
end
end

registerCoreBindings()

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'synex_core' then return end
    local ok = pcall(registerCoreBindings)
    if not ok then runtimeErrorSink({ operation = 'core_restart_registration', traceId = 'unavailable' }) end
end)
