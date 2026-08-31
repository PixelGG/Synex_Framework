SynexSecurityHardening = {}

local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')
local Hardening = SynexSecurityHardening

local REQUEST_CONTROL = {
    [-1] = 'Equivalent to mode 2 on current artifacts and emits a console warning.',
    [0] = 'Off; routing-bucket and entity-lockdown request-control policy is also disabled.',
    [1] = 'Blocks requests for settled player-controlled entities.',
    [2] = 'Blocks requests for all player-controlled entities.',
    [3] = 'Mode 2 plus settled non-player entities.',
    [4] = 'Does not route REQUEST_CONTROL_EVENT.',
}

local LOCKDOWN = {
    strict = 'Clients cannot create entities in the bucket.',
    relaxed = 'Client script-owned entity creation is blocked.',
    inactive = 'Clients may create entities.',
    full = 'Disables dummy object creation on supporting FiveM for GTAV Enhanced artifacts.',
    no_dummy = 'Legacy artifact/source vocabulary for Enhanced dummy-object lockdown.',
}

local function booleanValue(value)
    if type(value) == 'boolean' then return value end
    if type(value) == 'number' then return value ~= 0 end
    if type(value) ~= 'string' then return nil end
    value = value:lower()
    if value == '1' or value == 'true' or value == 'yes' or value == 'on' then
        return true
    end
    if value == '0' or value == 'false' or value == 'no' or value == 'off' then
        return false
    end
    return nil
end

function Hardening.create(options)
    options = options or {}
    local getConvar = assert(options.getConvar,
        'security hardening ConVar reader is required')
    assert(Validation.isCallable(getConvar),
        'security hardening ConVar reader is invalid')
    local getBuckets = Validation.isCallable(options.getBuckets)
        and options.getBuckets or nil
    local findingsLimit = math.max(8, math.min(128,
        tonumber(options.findingsLimit) or 64))
    local api = {}

    local function read(name, fallback)
        local ok, value = pcall(getConvar, name, fallback)
        if not ok or value == nil then return fallback end
        if type(value) ~= 'string' and type(value) ~= 'number'
            and type(value) ~= 'boolean' then return fallback end
        if type(value) == 'string' and #value > 128 then return fallback end
        return value
    end

    local function finding(result, value)
        if #result < findingsLimit then result[#result + 1] = value end
    end

    function api.list()
        local result = {}
        local requestControlRaw = read('sv_filterRequestControl', '0')
        local requestControl = tonumber(requestControlRaw)
        local requestSemantics = requestControl ~= nil
            and REQUEST_CONTROL[math.floor(requestControl)] or nil
        finding(result, {
            setting = 'sv_filterRequestControl',
            current = tostring(requestControlRaw),
            recommended = '2 (baseline; evaluate 3 or 4 for compatible servers)',
            status = requestSemantics == nil and 'UNKNOWN'
                or requestControl == 0 and 'ACTION_RECOMMENDED'
                or requestControl == -1 and 'REVIEW'
                or 'OK',
            reason = requestSemantics
                or 'The current value is outside the officially documented -1 through 4 modes.',
            compatibilityImpact = 'Modes 3 and 4 may break resources that depend on client control migration.',
            mutatesConfig = false,
        })

        local pureLevelRaw = read('sv_pureLevel', '0')
        local pureLevel = tonumber(pureLevelRaw)
        finding(result, {
            setting = 'sv_pureLevel', current = tostring(pureLevelRaw),
            recommended = '1 or 2 after client-mod compatibility review',
            status = pureLevel ~= nil and pureLevel >= 1 and pureLevel <= 2
                and 'OK' or 'ACTION_RECOMMENDED',
            reason = 'Pure mode can reject modified client files; level 2 also blocks known graphics modifications.',
            compatibilityImpact = 'May reject audio, graphics, or other client modifications depending on level.',
            mutatesConfig = false,
        })

        local verifyRaw = read('sv_pure_verify_client_settings', 'false')
        local verify = booleanValue(verifyRaw)
        finding(result, {
            setting = 'sv_pure_verify_client_settings', current = tostring(verifyRaw),
            recommended = 'true', status = verify == true and 'OK' or 'ACTION_RECOMMENDED',
            reason = 'Enables adhesive-to-svadhesive verification for relevant server settings.',
            compatibilityImpact = 'Review connection behavior on the target FXServer artifact before rollout.',
            mutatesConfig = false,
        })

        local replayRaw = read('sv_disableClientReplays', 'false')
        local replay = booleanValue(replayRaw)
        finding(result, {
            setting = 'sv_disableClientReplays', current = tostring(replayRaw),
            recommended = 'true when Rockstar Editor is not required',
            status = replay == true and 'OK' or 'REVIEW',
            reason = 'Cfx documents this as reducing some cheating opportunities.',
            compatibilityImpact = 'Enabling it disables Rockstar Editor.',
            mutatesConfig = false,
        })

        local stateBagRaw = read('sv_stateBagStrictMode', 'false')
        local stateBag = booleanValue(stateBagRaw)
        finding(result, {
            setting = 'sv_stateBagStrictMode', current = tostring(stateBagRaw),
            recommended = 'true only after state-bag ownership compatibility review',
            status = stateBag == true and 'OK' or 'REVIEW',
            reason = stateBag == true
                and 'Only the server may modify replicated entity and player state bags.'
                or 'Network owners may modify state bags they own under the current policy.',
            compatibilityImpact = 'Can break resources that intentionally write replicated state from clients.',
            mutatesConfig = false,
        })

        local globalLockdown = tostring(read('sv_entityLockdown', 'inactive')):lower()
        finding(result, {
            setting = 'sv_entityLockdown', current = globalLockdown,
            recommended = 'relaxed or strict after entity-authoring compatibility review',
            status = LOCKDOWN[globalLockdown] == nil and 'UNKNOWN'
                or globalLockdown == 'inactive' and 'REVIEW'
                or (globalLockdown == 'full' or globalLockdown == 'no_dummy')
                    and 'COMPATIBILITY_RISK' or 'OK',
            reason = LOCKDOWN[globalLockdown]
                or 'The current entity lockdown value is not recognized by the reviewed server source.',
            compatibilityImpact = globalLockdown == 'full'
                and 'full is documented for GTAV Enhanced and remains artifact-specific; it is never enabled automatically.'
                or globalLockdown == 'no_dummy'
                    and 'no_dummy is legacy GTAV Enhanced artifact/source vocabulary; verify the deployed artifact before use.'
                or 'Strict blocks every client-authored entity; relaxed blocks client script-owned entities.',
            mutatesConfig = false,
        })

        for _, name in ipairs({ 'sv_authMinTrust', 'sv_authMaxVariance' }) do
            finding(result, {
                setting = name, current = tostring(read(name, 'artifact-default')),
                recommended = 'operator-defined identity policy', status = 'REVIEW',
                reason = 'Cfx identity trust and variance thresholds have deployment-specific tradeoffs.',
                compatibilityImpact = 'Overly strict values may reject legitimate identity-provider changes.',
                mutatesConfig = false,
            })
        end

        if getBuckets ~= nil then
            local ok, buckets = pcall(getBuckets)
            if ok and type(buckets) == 'table' then
                local copied = 0
                for _, bucket in ipairs(buckets) do
                    if copied >= 32 then break end
                    local id, bucketMode = tonumber(bucket.id), tostring(bucket.mode or ''):lower()
                    if Validation.isInteger(id, 0, 2147483647) then
                        finding(result, {
                            setting = 'routingBucket.' .. tostring(id) .. '.entityLockdown',
                            current = bucketMode,
                            recommended = bucket.controlled == true and 'strict' or 'deployment-specific',
                            status = LOCKDOWN[bucketMode] == nil and 'UNKNOWN'
                                or (bucketMode == 'full' or bucketMode == 'no_dummy')
                                    and 'COMPATIBILITY_RISK'
                                or bucket.controlled == true and bucketMode == 'inactive'
                                    and 'ACTION_RECOMMENDED' or 'OK',
                            reason = LOCKDOWN[bucketMode]
                                or 'The bucket lockdown mode is not recognized by the reviewed source.',
                            compatibilityImpact = bucketMode == 'full'
                                and 'full is documented for GTAV Enhanced and remains artifact-specific.'
                                or bucketMode == 'no_dummy'
                                    and 'no_dummy is legacy GTAV Enhanced artifact/source vocabulary; verify the live artifact.'
                                or 'Strict is appropriate only when all entity creation is server-authoritative.',
                            mutatesConfig = false,
                        })
                        copied = copied + 1
                    end
                end
            end
        end
        return result
    end

    function api.semantics()
        local requestControl, lockdown = {}, {}
        for key, value in pairs(REQUEST_CONTROL) do requestControl[tostring(key)] = value end
        for key, value in pairs(LOCKDOWN) do lockdown[key] = value end
        return { requestControl = requestControl, entityLockdown = lockdown,
            lockdownDocumentationMismatch = {
                documented = 'full', reviewedServerSource = 'no_dummy',
                liveVerificationRequired = true,
            } }
    end

    function api.snapshot()
        local values = api.list()
        local counts = { OK = 0, REVIEW = 0, ACTION_RECOMMENDED = 0,
            COMPATIBILITY_RISK = 0, UNKNOWN = 0 }
        for _, value in ipairs(values) do
            counts[value.status] = (counts[value.status] or 0) + 1
        end
        return {
            readOnly = true,
            findings = #values,
            counts = counts,
        }
    end

    function api.inspect()
        local items = api.list()
        return {
            items = items,
            total = #items,
            hasMore = false,
            truncated = false,
            readOnly = true,
            semantics = api.semantics(),
        }
    end

    return api
end
