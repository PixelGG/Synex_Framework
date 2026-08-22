local CORE_RESOURCE = 'synex_core'
local CORE_RANGE = '^1.0.0'
local VIEW_ACE = 'synex.control.view'
local requestBuckets = {}
local cachedSnapshot
local cachedAt = 0

local SECTION_ORDER = {
    'overview', 'runtime', 'resources', 'dependencies', 'contracts', 'capabilities',
    'rpc', 'hooks', 'database', 'migrations', 'sessions', 'characters', 'groups',
    'accounts', 'ledger', 'entities', 'audit', 'tracing', 'performance', 'security',
    'compatibility',
}

local redactedKeys = {
    authorization = true, connectionstring = true, credential = true, credentials = true,
    identifier = true, identifiers = true, license = true, license2 = true,
    password = true, secret = true, token = true, webhook = true,
}

local maskedKeys = {
    accountid = true, actorid = true, actorref = true, characterid = true,
    grantid = true, holdid = true, idempotencykey = true, membershipid = true,
    ownerid = true, ownerref = true, principalref = true, sessionid = true,
    reference = true, subjectid = true, subjectref = true, targetid = true, transactionid = true,
    userid = true,
}

local function normalizeKey(key)
    return type(key) == 'string' and key:lower():gsub('[^a-z0-9]', '') or ''
end

local function isFinite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function boundedString(value, maximum)
    value = tostring(value)
    if #value <= maximum then return value end
    return value:sub(1, maximum - 3) .. '...'
end

local function maskIdentifier(value)
    if type(value) ~= 'string' then return '[MASKED]' end
    if #value <= 8 then return '****' end
    return value:sub(1, 4) .. '...' .. value:sub(-4)
end

local function isRedactedKey(key)
    local normalized = normalizeKey(key)
    return redactedKeys[normalized] == true
        or normalized:find('password', 1, true) ~= nil
        or normalized:find('secret', 1, true) ~= nil
        or normalized:find('credential', 1, true) ~= nil
        or normalized:find('webhook', 1, true) ~= nil
end

local function isArray(value)
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then return false, 0 end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    return maximum == count, count
end

local function sanitize(value, budget, depth, seen, parentKey)
    local valueType = type(value)
    if maskedKeys[normalizeKey(parentKey)] then return maskIdentifier(value) end
    if valueType == 'nil' or valueType == 'boolean' then return value end
    if valueType == 'number' then return isFinite(value) and value or '[NON_FINITE]' end
    if valueType == 'string' then
        return boundedString(value, SynexControlLimits.maximumStringBytes)
    end
    if valueType ~= 'table' then return ('[%s]'):format(valueType:upper()) end
    if depth >= SynexControlLimits.maximumDepth then return '[DEPTH_LIMIT]' end
    if seen[value] then return '[CYCLE]' end

    seen[value] = true
    local array, count = isArray(value)
    local output = {}
    if array then
        for index = 1, count do
            if budget.remaining <= 0 then
                output[#output + 1] = '[ENTRY_LIMIT]'
                break
            end
            budget.remaining = budget.remaining - 1
            output[#output + 1] = sanitize(value[index], budget, depth + 1, seen)
        end
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
        for _, key in ipairs(keys) do
            if budget.remaining <= 0 then
                output.__truncated = true
                break
            end
            budget.remaining = budget.remaining - 1
            local safeKey = boundedString(key, SynexControlLimits.maximumKeyBytes)
            if isRedactedKey(key) then output[safeKey] = '[REDACTED]'
            else output[safeKey] = sanitize(value[key], budget, depth + 1, seen, key) end
        end
    end
    seen[value] = nil
    return output
end

local function unavailable(code)
    return { available = false, error = type(code) == 'string' and code or 'UNAVAILABLE' }
end

local function available(value)
    return {
        available = true,
        value = sanitize(value, {
            remaining = SynexControlLimits.maximumEntriesPerSection,
        }, 0, {}),
    }
end

local function readValue(handler)
    if type(handler) ~= 'function' then return unavailable('NOT_EXPOSED') end
    local ok, value, readError = pcall(handler)
    if not ok or value == nil then
        local code = type(readError) == 'table' and readError.code or 'UNAVAILABLE'
        return unavailable(code)
    end
    return available(value)
end

local function acquireApi()
    if GetResourceState(CORE_RESOURCE) ~= 'started' then return nil end
    local ok, api = pcall(function() return exports[CORE_RESOURCE]:GetAPI(CORE_RANGE) end)
    return ok and type(api) == 'table' and api or nil
end

local function valueOf(result)
    return result and result.available and result.value or nil
end

local function exposed(container, key, missingCode)
    if type(container) ~= 'table' or container[key] == nil then
        return unavailable(missingCode or 'NOT_EXPOSED')
    end
    return available(container[key])
end

local function optionalCoreSection(container, key, missingCode)
    if type(container) ~= 'table' or container[key] == nil then
        return unavailable(missingCode or 'NOT_EXPOSED')
    end
    local value = container[key]
    if type(value) == 'table' and value.available == false then
        return unavailable(value.error)
    end
    if type(value) == 'table' and value.available == true and value.value ~= nil then
        return available(value.value)
    end
    return available(value)
end

local function findDoctorCheck(doctor, name)
    for _, check in ipairs(type(doctor) == 'table' and doctor.checks or {}) do
        if check.name == name then return check end
    end
    return nil
end

local function compatibilityFromResources(resources)
    local matches = {}
    local entries = type(resources) == 'table' and resources.entries or resources
    for _, entry in ipairs(type(entries) == 'table' and entries or {}) do
        local name = type(entry) == 'table' and (entry.name or entry.resource) or nil
        if type(name) == 'string' and (
            name == 'synex_bridge' or name == 'es_extended' or name == 'qb-core'
            or name == 'qbx_core' or name == 'ox_core'
        ) then
            matches[#matches + 1] = entry
        end
    end
    return { detectedResources = matches }
end

local function callService(api, name, method)
    return readValue(api and api.Services and function()
        return api.Services.call(name, '^1.0.0', method, {}, {})
    end or nil)
end

local function traceSearch(api, query)
    if not query then return unavailable('SEARCH_REQUIRED') end
    local diagnostics = api and api.Diagnostics
    local handler = diagnostics and (
        diagnostics.search or diagnostics.searchControl or diagnostics.searchTraces
    )
    if type(handler) ~= 'function' then return unavailable('NOT_EXPOSED') end
    return readValue(function()
        return handler({ kind = query.kind, value = query.value, limit = 64 })
    end)
end

local function enforcePayloadLimit(snapshot)
    local ok, encoded = pcall(json.encode, snapshot)
    if ok and #encoded <= SynexControlLimits.maximumSnapshotBytes then return snapshot end
    local reductionOrder = {
        'audit', 'tracing', 'performance', 'security', 'capabilities', 'contracts',
        'hooks', 'rpc', 'dependencies', 'resources', 'ledger', 'groups', 'accounts',
        'entities', 'compatibility', 'characters', 'sessions', 'database', 'migrations',
    }
    for _, sectionName in ipairs(reductionOrder) do
        if snapshot.sections[sectionName] and snapshot.sections[sectionName].available then
            snapshot.sections[sectionName] = unavailable('PAYLOAD_LIMIT')
            ok, encoded = pcall(json.encode, snapshot)
            if ok and #encoded <= SynexControlLimits.maximumSnapshotBytes then return snapshot end
        end
    end
    local sections = {}
    for _, sectionName in ipairs(SECTION_ORDER) do
        sections[sectionName] = unavailable('PAYLOAD_LIMIT')
    end
    return {
        schemaVersion = 1,
        generatedAt = snapshot.generatedAt,
        readOnly = true,
        sectionOrder = SECTION_ORDER,
        sections = sections,
    }
end

local function buildSnapshot(query)
    local api = acquireApi()
    if not api then
        local sections = {}
        for _, sectionName in ipairs(SECTION_ORDER) do sections[sectionName] = unavailable('CORE_UNAVAILABLE') end
        return {
            schemaVersion = 1,
            generatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            readOnly = true,
            sectionOrder = SECTION_ORDER,
            sections = sections,
        }
    end

    local coreResult = readValue(api.Diagnostics and api.Diagnostics.getControlSnapshot)
    local doctorResult = readValue(api.Diagnostics and api.Diagnostics.run)
    local groupsResult = callService(api, 'synex.groups', 'get_control_summary')
    local accountsResult = callService(api, 'synex.accounts', 'get_control_summary')
    local entitiesResult = callService(api, 'synex.entities', 'getControlSummary')
    local core = valueOf(coreResult)
    local doctor = valueOf(doctorResult)
    local groups = valueOf(groupsResult)
    local accounts = valueOf(accountsResult)
    local entities = valueOf(entitiesResult)
    local resources = core and core.resources
    local resourceEntries = type(resources) == 'table' and resources.entries or resources
    local searchResult = query and traceSearch(api, query) or nil

    local overview
    if core then
        overview = available({
            schemaVersion = core.schemaVersion,
            lifecycle = core.runtime and core.runtime.lifecycle,
            environment = core.runtime and core.runtime.environment,
            apiVersion = core.runtime and core.runtime.apiVersion,
            diagnosticStatus = doctor and doctor.status,
            registeredResources = type(resourceEntries) == 'table' and #resourceEntries or nil,
            groups = groups and groups.overview,
            accounts = accounts and accounts.overview,
            entities = entities and entities.runtime,
        })
    else
        overview = unavailable(coreResult.error)
    end

    local migration = doctor and findDoctorCheck(doctor, 'migrations')
    local sections = {
        overview = overview,
        runtime = core and exposed(core, 'runtime') or unavailable(coreResult.error),
        resources = core and exposed(core, 'resources') or unavailable(coreResult.error),
        dependencies = core and exposed(core, 'dependencies') or unavailable(coreResult.error),
        contracts = core and exposed(core, 'contracts') or unavailable(coreResult.error),
        capabilities = core and exposed(core, 'capabilities') or unavailable(coreResult.error),
        rpc = core and available({ rpc = core.rpc, services = core.services, events = core.events })
            or unavailable(coreResult.error),
        hooks = core and exposed(core, 'hooks') or unavailable(coreResult.error),
        database = core and exposed(core, 'database') or unavailable(coreResult.error),
        migrations = core and core.migrations ~= nil and optionalCoreSection(core, 'migrations')
            or (migration and available(migration) or unavailable('NOT_EXPOSED')),
        sessions = core and exposed(core, 'sessions') or unavailable(coreResult.error),
        characters = core and exposed(core, 'characters') or unavailable(coreResult.error),
        groups = groupsResult,
        accounts = accounts and available({ overview = accounts.overview, currencies = accounts.currencies,
            integrity = accounts.integrity, anomalies = accounts.anomalies }) or unavailable(accountsResult.error),
        ledger = accounts and available(accounts.ledger) or unavailable(accountsResult.error),
        entities = entitiesResult,
        audit = searchResult or (core and optionalCoreSection(core, 'audit') or unavailable('NOT_EXPOSED')),
        tracing = core and optionalCoreSection(core, 'tracing') or unavailable('NOT_EXPOSED'),
        performance = core and exposed(core, 'performance') or unavailable(coreResult.error),
        security = core and exposed(core, 'security') or unavailable(coreResult.error),
        compatibility = core and (core.compatibility ~= nil
            and optionalCoreSection(core, 'compatibility')
            or available(compatibilityFromResources(resources))) or unavailable(coreResult.error),
    }
    return enforcePayloadLimit({
        schemaVersion = 1,
        generatedAt = core and core.generatedAt or os.date('!%Y-%m-%dT%H:%M:%SZ'),
        readOnly = true,
        search = query and { kind = query.kind, value = maskIdentifier(query.value) } or nil,
        sectionOrder = SECTION_ORDER,
        sections = sections,
    })
end

local function mayView(playerSource)
    return type(playerSource) == 'number' and playerSource > 0
        and GetPlayerName(tostring(playerSource)) ~= nil
        and IsPlayerAceAllowed(tostring(playerSource), VIEW_ACE)
end

local function takeRequestTokens(playerSource, cost)
    local now = GetGameTimer()
    local bucket = requestBuckets[playerSource]
    if not bucket then
        bucket = { tokens = SynexControlLimits.serverBurst, updatedAt = now }
        requestBuckets[playerSource] = bucket
    end
    local elapsed = math.max(0, now - bucket.updatedAt) / 1000
    bucket.tokens = math.min(SynexControlLimits.serverBurst,
        bucket.tokens + elapsed * SynexControlLimits.serverRefillPerSecond)
    bucket.updatedAt = now
    if bucket.tokens < cost then return false end
    bucket.tokens = bucket.tokens - cost
    return true
end

local function validateSearch(request)
    if type(request) ~= 'table' then return nil end
    for key in pairs(request) do if key ~= 'kind' and key ~= 'value' then return nil end end
    local kinds = { trace = true, character = true, transaction = true, resource = true }
    if not kinds[request.kind] or type(request.value) ~= 'string'
        or #request.value < 2 or #request.value > SynexControlLimits.maximumSearchBytes then return nil end
    if request.kind == 'resource' then
        if request.value:match('^[a-z][a-z0-9_%-]*$') == nil then return nil end
    elseif request.value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
        return nil
    end
    return { kind = request.kind, value = request.value }
end

local function sendSnapshot(playerSource, shouldOpen, query)
    if not mayView(playerSource) or not takeRequestTokens(playerSource, query and 2 or 1) then return end
    local snapshot
    local now = GetGameTimer()
    if not query and cachedSnapshot and now - cachedAt < SynexControlLimits.serverCacheMilliseconds then
        snapshot = cachedSnapshot
    else
        snapshot = buildSnapshot(query)
        if not query then cachedSnapshot, cachedAt = snapshot, now end
    end
    TriggerClientEvent('synex_control:snapshot', playerSource, {
        open = shouldOpen == true,
        snapshot = snapshot,
    })
end

RegisterCommand('synex-control', function(playerSource)
    if playerSource > 0 then sendSnapshot(playerSource, true) end
end, false)

RegisterNetEvent('synex_control:refresh', function()
    local playerSource = source
    sendSnapshot(playerSource, false)
end)

RegisterNetEvent('synex_control:search', function(request)
    local playerSource = source
    local query = validateSearch(request)
    if not query then return end
    sendSnapshot(playerSource, false, query)
end)

AddEventHandler('playerDropped', function()
    local playerSource = source
    requestBuckets[playerSource] = nil
end)
