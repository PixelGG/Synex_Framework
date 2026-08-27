local Constants = require 'server.domain.constants'

local Capabilities = {}

local DEFAULT_MAXIMUM_RULES = 256
local DEFAULT_MAXIMUM_ROLES = 32
local DEFAULT_MAXIMUM_DELEGATIONS = 64
local DEFAULT_MAXIMUM_SCOPE_KEYS = 16

local function domainError(code, message, details)
    return { code = code, message = message, retryable = false, details = details }
end

local function validIdentifier(value)
    return type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
end

local function validCapability(value)
    if type(value) ~= 'string' or #value < 1 or #value > 128 or value ~= value:lower()
        or value:sub(1, 1) == '.' or value:sub(-1) == '.' or value:find('..', 1, true) then
        return false
    end
    local base = value
    if value:sub(-2) == '.*' then
        base = value:sub(1, -3)
    elseif value:find('*', 1, true) then
        return false
    end
    local count = 0
    for segment in base:gmatch('[^.]+') do
        count = count + 1
        if not segment:match('^[a-z][a-z0-9_%-]*$') then return false end
    end
    return count > 0
end

local function arrayLength(value, maximum)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil end
    local count, highest = 0, 0
    for key in pairs(value) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
        count = count + 1
        if count > maximum then return nil end
        highest = math.max(highest, key)
    end
    if highest ~= count then return nil end
    return count
end

local function validTimestamp(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
        and math.type(value) == 'integer' and value >= 0
end

local function validateWindow(validFrom, validUntil)
    if validFrom ~= nil and not validTimestamp(validFrom) then
        return nil, domainError('CAPABILITY_TIME_INVALID', 'validFrom must be a non-negative integer timestamp.')
    end
    if validUntil ~= nil and not validTimestamp(validUntil) then
        return nil, domainError('CAPABILITY_TIME_INVALID', 'validUntil must be a non-negative integer timestamp.')
    end
    if validFrom ~= nil and validUntil ~= nil and validUntil <= validFrom then
        return nil, domainError('CAPABILITY_TIME_INVALID', 'validUntil must be greater than validFrom.')
    end
    return true, nil
end

local function validateScope(scope, maximumKeys)
    if scope == nil then return true, nil end
    if type(scope) ~= 'table' or getmetatable(scope) ~= nil then
        return nil, domainError('CAPABILITY_SCOPE_INVALID', 'Capability scope must be a plain object.')
    end
    local count = 0
    for key, value in pairs(scope) do
        count = count + 1
        if count > maximumKeys then
            return nil, domainError('CAPABILITY_SCOPE_TOO_LARGE', 'Capability scope exceeds its key limit.')
        end
        if type(key) ~= 'string' or #key < 1 or #key > 64 or not key:match('^[a-z][a-zA-Z0-9_]*$') then
            return nil, domainError('CAPABILITY_SCOPE_INVALID', 'Capability scope contains an invalid key.')
        end
        local valueType = type(value)
        if valueType == 'string' then
            if #value < 1 or #value > 128 then
                return nil, domainError('CAPABILITY_SCOPE_INVALID', 'Capability scope contains an invalid string value.')
            end
        elseif valueType == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then
                return nil, domainError('CAPABILITY_SCOPE_INVALID', 'Capability scope contains an invalid number.')
            end
        elseif valueType ~= 'boolean' then
            return nil, domainError('CAPABILITY_SCOPE_INVALID', 'Capability scope values must be scalar.')
        end
    end
    return true, nil
end

local function scopeMatches(ruleScope, requestedScope)
    if ruleScope == nil then return true end
    requestedScope = requestedScope or {}
    for key, expected in pairs(ruleScope) do
        local actual = requestedScope[key]
        if expected == '*' then
            if actual == nil then return false end
        elseif actual ~= expected then
            return false
        end
    end
    return true
end

local function copyScope(scope)
    local copied = {}
    for key, value in pairs(scope or {}) do copied[key] = value end
    return copied
end

local function validateRule(rule, maximumScopeKeys)
    if type(rule) ~= 'table' or getmetatable(rule) ~= nil then
        return nil, domainError('CAPABILITY_RULE_INVALID', 'Capability rules must be plain objects.')
    end
    local allowed = {
        id = true, capability = true, effect = true, scope = true,
        validFrom = true, validUntil = true, delegable = true
    }
    for key in pairs(rule) do
        if not allowed[key] then
            return nil, domainError('CAPABILITY_RULE_INVALID', 'Capability rule contains an unknown property.', {
                property = tostring(key)
            })
        end
    end
    if rule.id ~= nil and not validIdentifier(rule.id) then
        return nil, domainError('CAPABILITY_RULE_INVALID', 'Capability rule id is invalid.')
    end
    if not validCapability(rule.capability)
        or (rule.effect ~= Constants.EFFECT.ALLOW and rule.effect ~= Constants.EFFECT.DENY) then
        return nil, domainError('CAPABILITY_RULE_INVALID', 'Capability rule pattern or effect is invalid.')
    end
    if rule.delegable ~= nil and type(rule.delegable) ~= 'boolean' then
        return nil, domainError('CAPABILITY_RULE_INVALID', 'Capability rule delegability must be a boolean.')
    end
    if rule.effect == Constants.EFFECT.DENY and rule.delegable == true then
        return nil, domainError('CAPABILITY_RULE_INVALID', 'Deny rules cannot be delegable.')
    end
    local scopeValid, scopeError = validateScope(rule.scope, maximumScopeKeys)
    if not scopeValid then return nil, scopeError end
    return validateWindow(rule.validFrom, rule.validUntil)
end

local function validateSource(source, maximumRules)
    if type(source) ~= 'table' or getmetatable(source) ~= nil then
        return nil, domainError('CAPABILITY_SOURCE_INVALID', 'Capability source must be a plain object.')
    end
    local allowed = {
        id = true, rules = true, validFrom = true, validUntil = true, revoked = true
    }
    for key in pairs(source) do
        if not allowed[key] then
            return nil, domainError('CAPABILITY_SOURCE_INVALID', 'Capability source contains an unknown property.', {
                property = tostring(key)
            })
        end
    end
    if not validIdentifier(source.id) or arrayLength(source.rules, maximumRules) == nil
        or (source.revoked ~= nil and type(source.revoked) ~= 'boolean') then
        return nil, domainError('CAPABILITY_SOURCE_INVALID', 'Capability source id, rules, or revoked state is invalid.')
    end
    return validateWindow(source.validFrom, source.validUntil)
end

local function sourceInactiveReason(source, now)
    if source and source.revoked == true then return 'SOURCE_REVOKED' end
    if source and source.validFrom ~= nil and now < source.validFrom then return 'SOURCE_NOT_YET_VALID' end
    if source and source.validUntil ~= nil and now >= source.validUntil then return 'SOURCE_EXPIRED' end
    return nil
end

local function ruleEligibilityReason(rule, request, inactiveReason)
    if inactiveReason then return inactiveReason end
    if rule.validFrom ~= nil and request.now < rule.validFrom then return 'RULE_NOT_YET_VALID' end
    if rule.validUntil ~= nil and request.now >= rule.validUntil then return 'RULE_EXPIRED' end
    if not scopeMatches(rule.scope, request.scope) then return 'SCOPE_MISMATCH' end
    return 'ELIGIBLE'
end

function Capabilities.create(options)
    options = options or {}
    if type(options) ~= 'table' or getmetatable(options) ~= nil then
        error('capability options must be a plain object', 2)
    end
    local allowedOptions = {
        now = true, maximumRules = true, maximumRoles = true,
        maximumDelegations = true, maximumScopeKeys = true,
        evaluateRules = true
    }
    for key in pairs(options) do
        if not allowedOptions[key] then error('capability options contain an unknown property', 2) end
    end
    local now = options.now or os.time
    local maximumRules = options.maximumRules or DEFAULT_MAXIMUM_RULES
    local maximumRoles = options.maximumRoles or DEFAULT_MAXIMUM_ROLES
    local maximumDelegations = options.maximumDelegations or DEFAULT_MAXIMUM_DELEGATIONS
    local maximumScopeKeys = options.maximumScopeKeys or DEFAULT_MAXIMUM_SCOPE_KEYS
    local coreEvaluateRules = options.evaluateRules
    if type(now) ~= 'function'
        or type(coreEvaluateRules) ~= 'function'
        or type(maximumRules) ~= 'number' or math.type(maximumRules) ~= 'integer' or maximumRules < 1 or maximumRules > 1024
        or type(maximumRoles) ~= 'number' or math.type(maximumRoles) ~= 'integer' or maximumRoles < 0 or maximumRoles > 128
        or type(maximumDelegations) ~= 'number' or math.type(maximumDelegations) ~= 'integer'
            or maximumDelegations < 0 or maximumDelegations > 256
        or type(maximumScopeKeys) ~= 'number' or math.type(maximumScopeKeys) ~= 'integer'
            or maximumScopeKeys < 0 or maximumScopeKeys > 32 then
        error('capability options are outside supported bounds or omit the Core rule evaluator', 2)
    end

    local evaluator = {}

    function evaluator:evaluate(input)
        if type(input) ~= 'table' or getmetatable(input) ~= nil then
            return nil, domainError('CAPABILITY_REQUEST_INVALID', 'Capability request must be a plain object.')
        end
        local allowed = {
            capability = true, scope = true, at = true, defaults = true,
            grade = true, roles = true, membership = true, delegations = true
        }
        for key in pairs(input) do
            if not allowed[key] then
                return nil, domainError('CAPABILITY_REQUEST_INVALID', 'Capability request contains an unknown property.', {
                    property = tostring(key)
                })
            end
        end
        if not validCapability(input.capability) then
            return nil, domainError('CAPABILITY_REQUEST_INVALID', 'Requested capability is invalid.')
        end
        local scopeValid, scopeError = validateScope(input.scope, maximumScopeKeys)
        if not scopeValid then return nil, scopeError end
        local evaluatedAt = input.at
        if evaluatedAt == nil then
            local clockOk, clockValue = pcall(now)
            if not clockOk then
                return nil, domainError('CAPABILITY_CLOCK_FAILED', 'Capability clock failed closed.')
            end
            evaluatedAt = clockValue
        end
        if not validTimestamp(evaluatedAt) then
            return nil, domainError('CAPABILITY_TIME_INVALID', 'Capability evaluation time is invalid.')
        end

        local defaults = input.defaults or {}
        local roles = input.roles or {}
        local delegations = input.delegations or {}
        if arrayLength(defaults, maximumRules) == nil
            or arrayLength(roles, maximumRoles) == nil
            or arrayLength(delegations, maximumDelegations) == nil then
            return nil, domainError('CAPABILITY_REQUEST_INVALID', 'Capability source collections must be bounded dense arrays.')
        end

        local result = {
            capability = input.capability,
            scope = copyScope(input.scope),
            evaluatedAt = evaluatedAt,
            allowed = false,
            denied = false,
            matchedAllows = 0,
            matchedDenies = 0,
            matchedDelegableAllows = 0,
            delegable = false,
            evaluatedRules = 0,
            trace = {}
        }
        local request = { capability = input.capability, scope = input.scope, now = evaluatedAt }
        local candidates, candidateTraceIndexes = {}, {}

        local function evaluateRules(rules, layer, sourceId, inactiveReason)
            local count = arrayLength(rules, maximumRules)
            if count == nil or result.evaluatedRules + count > maximumRules then
                return nil, domainError('CAPABILITY_RULE_LIMIT', 'Capability composition exceeds its rule limit.')
            end
            for index = 1, count do
                local rule = rules[index]
                local ruleValid, ruleError = validateRule(rule, maximumScopeKeys)
                if not ruleValid then
                    ruleError.details = ruleError.details or {}
                    ruleError.details.layer = layer
                    ruleError.details.index = index
                    return nil, ruleError
                end
                result.evaluatedRules = result.evaluatedRules + 1
                local reason = ruleEligibilityReason(rule, request, inactiveReason)
                result.trace[#result.trace + 1] = {
                    layer = layer,
                    sourceId = sourceId,
                    ruleId = rule.id,
                    capability = rule.capability,
                    effect = rule.effect,
                    delegable = rule.delegable == true,
                    matched = false,
                    reason = reason == 'ELIGIBLE' and 'CAPABILITY_MISMATCH' or reason
                }
                if reason == 'ELIGIBLE' then
                    candidates[#candidates + 1] = {
                        permission = rule.capability,
                        effect = rule.effect
                    }
                    candidateTraceIndexes[#candidateTraceIndexes + 1] = #result.trace
                end
            end
            return true, nil
        end

        local evaluated, evaluationError = evaluateRules(defaults, 'defaults', 'defaults', nil)
        if not evaluated then return nil, evaluationError end

        local function evaluateSource(source, layer)
            local sourceValid, sourceError = validateSource(source, maximumRules)
            if not sourceValid then return nil, sourceError end
            return evaluateRules(source.rules, layer, source.id, sourceInactiveReason(source, evaluatedAt))
        end

        if input.grade ~= nil then
            evaluated, evaluationError = evaluateSource(input.grade, 'grade')
            if not evaluated then return nil, evaluationError end
        end
        for index = 1, #roles do
            evaluated, evaluationError = evaluateSource(roles[index], 'role')
            if not evaluated then return nil, evaluationError end
        end
        if input.membership ~= nil then
            evaluated, evaluationError = evaluateSource(input.membership, 'membership')
            if not evaluated then return nil, evaluationError end
        end
        for index = 1, #delegations do
            evaluated, evaluationError = evaluateSource(delegations[index], 'delegation')
            if not evaluated then return nil, evaluationError end
        end

        local coreOk, coreResult, coreError = pcall(
            coreEvaluateRules, input.capability, candidates)
        if not coreOk then
            return nil, domainError('CAPABILITY_ENGINE_FAILED',
                'The Synex Core permission evaluator failed closed.')
        end
        if type(coreResult) ~= 'table' then
            return nil, coreError or domainError('CAPABILITY_ENGINE_FAILED',
                'The Synex Core permission evaluator returned no decision.')
        end
        local matches = coreResult.matches
        if type(matches) ~= 'table' or #matches > #candidates
            or type(coreResult.allowed) ~= 'boolean'
            or type(coreResult.denied) ~= 'boolean' then
            return nil, domainError('CAPABILITY_ENGINE_RESULT_INVALID',
                'The Synex Core permission evaluator returned an invalid decision.')
        end
        local matchedCandidates, matchCount = {}, 0
        for key, match in pairs(matches) do
            matchCount = matchCount + 1
            local candidateIndex = type(match) == 'table' and tonumber(match.index) or nil
            if type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > #matches
                or not candidateIndex or math.type(candidateIndex) ~= 'integer'
                or candidateIndex < 1 or candidateIndex > #candidates
                or matchedCandidates[candidateIndex]
                or match.permission ~= candidates[candidateIndex].permission
                or match.effect ~= candidates[candidateIndex].effect then
                return nil, domainError('CAPABILITY_ENGINE_RESULT_INVALID',
                    'The Synex Core permission evaluator returned invalid match evidence.')
            end
            matchedCandidates[candidateIndex] = true
        end
        if matchCount ~= #matches then
            return nil, domainError('CAPABILITY_ENGINE_RESULT_INVALID',
                'The Synex Core permission evaluator returned sparse match evidence.')
        end
        for candidateIndex, traceIndex in ipairs(candidateTraceIndexes) do
            if matchedCandidates[candidateIndex] then
                local trace = result.trace[traceIndex]
                trace.matched = true
                trace.reason = 'MATCHED'
                if candidates[candidateIndex].effect == Constants.EFFECT.DENY then
                    result.matchedDenies = result.matchedDenies + 1
                else
                    result.matchedAllows = result.matchedAllows + 1
                    if trace.delegable then
                        result.matchedDelegableAllows = result.matchedDelegableAllows + 1
                    end
                end
            end
        end
        result.denied = result.matchedDenies > 0
        result.allowed = result.matchedAllows > 0 and not result.denied
        result.delegable = result.allowed and result.matchedDelegableAllows > 0
        if coreResult.denied ~= result.denied or coreResult.allowed ~= result.allowed then
            return nil, domainError('CAPABILITY_ENGINE_RESULT_INVALID',
                'The Synex Core permission evaluator decision conflicts with its evidence.')
        end
        result.decision = result.allowed and Constants.DECISION.ALLOW or Constants.DECISION.DENY
        if result.denied then
            result.reason = 'EXPLICIT_DENY'
        elseif result.allowed then
            result.reason = 'CAPABILITY_GRANTED'
        else
            result.reason = 'NO_MATCHING_ALLOW'
        end
        return result, nil
    end

    return evaluator
end

return Capabilities
