return function(options)
local suffix = assert(type(options) == 'table' and type(options.suffix) == 'string'
    and options.suffix, 'live Groups runtime requires a unique suffix')
local Foundation = require 'server.foundation'
local Validation = require('server.validation')(Foundation)

local function externalPlain(value, active)
    local valueType = type(value)
    if valueType ~= 'table' and valueType ~= 'userdata' then return value end
    active = active or {}
    if active[value] then error('cyclic external value', 0) end
    active[value] = true
    local copied = {}
    local length = valueType == 'userdata' and #value or 0
    if length > 0 then
        for index = 1, length do
            copied[index] = externalPlain(value[index], active)
        end
        active[value] = nil
        return copied
    end
    local iterable, iterator, state, first = pcall(pairs, value)
    if iterable then
        for key, child in iterator, state, first do
            if key ~= 'length' then copied[key] = externalPlain(child, active) end
        end
    end
    active[value] = nil
    return copied
end

local function databaseResult(promise)
    local result = externalPlain(promise:await())
    if type(result) == 'table' and result.__synex_live_database_error == true then
        error(Foundation.domainError('DATABASE_ERROR',
            'The live Groups database operation failed.', true, {
                driver_code = tostring(result.code or 'UNKNOWN_DATABASE_ERROR')
            }), 0)
    end
    return result
end

local function transactionView()
    local transaction = {}
    function transaction.query(_, sql, parameters)
        return databaseResult(LiveDatabaseQuery(sql, parameters)), nil
    end
    function transaction.many(_, sql, parameters)
        return databaseResult(LiveDatabaseQuery(sql, parameters)), nil
    end
    function transaction.one(_, sql, parameters)
        local rows = databaseResult(LiveDatabaseQuery(sql, parameters))
        return rows[1], nil
    end
    function transaction.affected(_, sql, parameters)
        local result = databaseResult(LiveDatabaseQuery(sql, parameters))
        return tonumber(result.affectedRows), nil
    end
    function transaction.insert(_, sql, parameters)
        local result = databaseResult(LiveDatabaseQuery(sql, parameters))
        return tonumber(result.insertId), nil
    end
    return transaction
end

local function retryableDeadlock(value)
    if type(value) ~= 'table' then return false end
    local details = type(value.details) == 'table' and value.details or {}
    local detail = tostring(details.driver_code or value.code or ''):lower()
    return detail:find('1213', 1, true) ~= nil
        or detail:find('40001', 1, true) ~= nil
        or detail:find('deadlock', 1, true) ~= nil
end

local CoreDatabase = {}
function CoreDatabase.null()
    return { __synex_database_null = true }
end
function CoreDatabase.read(request)
    return databaseResult(LiveDatabaseRead(request.sql, request.parameters)), nil
end
function CoreDatabase.write(request)
    return databaseResult(LiveDatabaseWrite(request.sql, request.parameters)), nil
end
function CoreDatabase.transaction(_, handler)
    -- Mirror synex_core's default deadlock policy: one attempt plus two retries.
    for attempt = 1, 3 do
        LiveDatabaseBegin():await()
        local called, value, operationError = pcall(handler, transactionView())
        if called and value ~= nil then
            LiveDatabaseCommit():await()
            return value, operationError, { replayed = false }
        end
        local failure = called and operationError or value
        LiveDatabaseRollback():await()
        if not retryableDeadlock(failure) or attempt == 3 then
            if called then return nil, operationError end
            return nil, type(value) == 'table' and value or Foundation.domainError(
                'DATABASE_ERROR', 'Live transaction handler failed.', true)
        end
    end
    return nil, Foundation.domainError('DATABASE_ERROR',
        'Live transaction deadlock retries were exhausted.', true)
end
function CoreDatabase.maintenance(_, handler)
    LiveDatabaseBegin():await()
    local called, value, operationError = pcall(handler, transactionView())
    if not called or value == nil then
        LiveDatabaseRollback():await()
        if called then return nil, operationError end
        return nil, type(value) == 'table' and value or Foundation.domainError(
            'DATABASE_ERROR', 'Live maintenance handler failed.', true)
    end
    LiveDatabaseCommit():await()
    return value, operationError
end

local function jsonEncode(value)
    return LiveJsonEncode(value)
end
local function jsonDecode(value)
    return externalPlain(LiveJsonDecode(value))
end
local function evaluateRules(permission, rules)
    local matches, allows, denies = {}, 0, 0
    for index, rule in ipairs(rules) do
        local pattern = rule.permission
        local matched = pattern == permission
        if not matched and type(pattern) == 'string' and pattern:sub(-2) == '.*' then
            local prefix = pattern:sub(1, -3)
            matched = permission:sub(1, #prefix + 1) == prefix .. '.'
        end
        if matched then
            matches[#matches + 1] = {
                index = index, permission = pattern, effect = rule.effect
            }
            if rule.effect == 'deny' then denies = denies + 1 else allows = allows + 1 end
        end
    end
    return {
        permission = permission,
        matches = matches,
        matchedAllows = allows,
        matchedDenies = denies,
        denied = denies > 0,
        allowed = allows > 0 and denies == 0,
        evaluatedRules = #rules
    }, nil
end

local createAdapter = require('server.database_adapter')(Foundation)
local coreDataPort = createAdapter(CoreDatabase)
local capabilityEvaluator = require('server.domain.capabilities').create({
    now = function() return os.time() end,
    maximumRules = 256,
    maximumRoles = 32,
    maximumDelegations = 64,
    maximumScopeKeys = 16,
    evaluateRules = evaluateRules
})
local policyEngine = require('server.domain.policy').create({
    capabilities = capabilityEvaluator,
    maximumGates = 16
})
local cache = require('server.cache')(Foundation)({ maximum = 256, ttlMs = 5000 })
local idSequence = 0
local function nextId(namespace)
    idSequence = idSequence + 1
    return namespace .. '_' .. suffix .. '_' .. string.format('%04d', idSequence)
end
local registry = {
    get = function() return nil, { code = 'REGISTRY_KEY_NOT_FOUND' } end,
    replace = function() return true end,
    stats = function()
        return { entries = 0, maximumEntries = 64, maximumPerOwner = 64 }
    end,
    listOwner = function() return {} end
}
local modules = {
    effects = require 'server.persistence.effects',
    approved_operations = require 'server.persistence.approved_operations',
    capability_access = require 'server.persistence.capability_access',
    organizations_read = require 'server.persistence.organizations_read',
    organizations_lifecycle = require 'server.persistence.organizations_lifecycle',
    memberships_invitations = require 'server.persistence.memberships_invitations',
    memberships_lifecycle = require 'server.persistence.memberships_lifecycle',
    membership_transition_policies =
        require 'server.persistence.membership_transition_policies',
    memberships_access = require 'server.persistence.memberships_access',
    governance_policies = require 'server.persistence.governance_policies',
    governance_attribute_activation =
        require 'server.persistence.governance_attribute_activation',
    workers = require 'server.persistence.workers'
}
local repository = require('server.persistence')(Foundation, modules)({
    dataPort = coreDataPort,
    jsonEncode = jsonEncode,
    jsonDecode = jsonDecode,
    nextId = nextId,
    capabilityEvaluator = capabilityEvaluator,
    policyEngine = policyEngine,
    cache = cache,
    registries = {
        groupTypes = registry,
        relationTypes = registry,
        attributeSchemas = registry,
        dutyStates = registry
    },
    applicationSchemas = {
        validateSchema = function() return true end,
        validateData = function() return true end
    },
    validateOperation = Validation.operation,
    runtimeIndex = { snapshot = function()
        return { characters = 0, memberships = 0, dutySessions = 0 }
    end },
    checkCorePermission = function() return true end,
    applyRegistryMutation = function() return true end,
    refreshRegistry = function() return true end
})

local auditEntries, runtimeEffects, unexpectedErrors = 0, 0, 0
local service = require('server.service')(Foundation)({
    repository = repository,
    characters = { get = function(characterId) return { id = characterId }, nil end },
    hooks = { run = function(_, value) return value, nil end },
    audit = { append = function()
        auditEntries = auditEntries + 1
        return { eventId = nextId('core_audit') }, nil
    end },
    runtimeEffects = { apply = function()
        runtimeEffects = runtimeEffects + 1
        return true, nil
    end },
    cache = cache,
    jsonEncode = jsonEncode,
    errorSink = function() unexpectedErrors = unexpectedErrors + 1 end
})

local runtime = {}

function runtime.decode(value)
    return jsonDecode(value)
end

function runtime.invoke(operation, request, context)
    local method = type(operation) == 'string' and service[operation] or nil
    if type(method) ~= 'function' then error('unsupported live Groups operation', 0) end
    local auditBefore = auditEntries
    local effectsBefore = runtimeEffects
    local errorsBefore = unexpectedErrors
    local value, operationError = method(request, context)
    return {
        operation = operation,
        ok = value ~= nil,
        value = value,
        error = operationError,
        auditEntries = auditEntries - auditBefore,
        runtimeEffects = runtimeEffects - effectsBefore,
        unexpectedErrors = unexpectedErrors - errorsBefore
    }
end

return runtime
end
