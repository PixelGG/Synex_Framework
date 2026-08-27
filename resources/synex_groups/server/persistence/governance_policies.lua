return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local POLICY_EFFECTS = Shared.POLICY_EFFECTS
local POLICY_STATUS = Shared.POLICY_STATUS
local POLICY_SUBJECTS = Shared.POLICY_SUBJECTS
local POLICY_SCOPES = Shared.POLICY_SCOPES
local rejected = Shared.rejected
local isObject = Shared.isObject
local arrayLength = Shared.arrayLength
local closedObject = Shared.closedObject
local publicId = Shared.publicId
local activeGroup = Shared.activeGroup
local reason = Shared.reason
local canonical = Shared.canonical
local copyJson = Shared.copyJson
local capabilityResult = Shared.capabilityResult
local handlers = { read = {}, execute = {} }

local function validatePolicyCondition(value)
    if value == nil then return nil, nil end
    local condition, copyError = copyJson(value, {
        maximumDepth = 4,
        maximumKeys = 64,
        maximumStringBytes = 512,
        preserveContainerKind = false
    })
    if not condition then return nil, copyError end
    local valid, validationError = closedObject(condition, {
        target_active = true,
        actor_rank_above_target = true,
        parameter = true,
        operator = true,
        value = true
    }, 'Policy condition')
    if not valid then return nil, validationError end
    if condition.target_active ~= nil and type(condition.target_active) ~= 'boolean'
        or condition.actor_rank_above_target ~= nil
            and type(condition.actor_rank_above_target) ~= 'boolean' then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Policy condition flags must be boolean.')
    end
    if condition.parameter ~= nil then
        if type(condition.parameter) ~= 'string' or #condition.parameter < 1
            or #condition.parameter > 64
            or not condition.parameter:match('^[a-z][a-z0-9_]*$') then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Policy condition parameter is invalid.')
        end
        if condition.operator ~= 'equals' and condition.operator ~= 'not_equals'
            and condition.operator ~= 'exists' and condition.operator ~= 'in' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Policy condition operator is invalid.')
        end
        if condition.operator ~= 'exists' and condition.value == nil then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Policy condition value is required for this operator.')
        end
        if condition.operator == 'in' then
            local count = arrayLength(condition.value, 32)
            if count == nil or count == 0 then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'Policy in conditions require a bounded non-empty scalar array.')
            end
            for index = 1, count do
                local itemType = type(condition.value[index])
                if itemType ~= 'string' and itemType ~= 'number'
                    and itemType ~= 'boolean' then
                    return nil, Foundation.domainError('VALIDATION_FAILED',
                        'Policy condition arrays may only contain scalar values.')
                end
            end
        elseif condition.value ~= nil and type(condition.value) ~= 'string'
            and type(condition.value) ~= 'number' and type(condition.value) ~= 'boolean' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Policy condition values must be scalar.')
        end
    elseif condition.operator ~= nil or condition.value ~= nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Policy condition operators require a parameter.')
    end
    return condition, nil
end

local function validatePolicyDefinition(action, value)
    local definition, copyError = copyJson(value, {
        maximumDepth = 6,
        maximumKeys = 512,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not definition then return nil, copyError end
    local valid, validationError = closedObject(definition, {
        display_name = true, default_effect = true, status = true, rules = true
    }, 'Policy definition')
    if not valid then return nil, validationError end
    local defaultEffect = definition.default_effect or 'deny'
    local status = definition.status or 'active'
    local displayName = definition.display_name or action
    if not POLICY_EFFECTS[defaultEffect] or not POLICY_STATUS[status]
        or type(displayName) ~= 'string' or Foundation.characterLength(displayName) < 1
        or Foundation.characterLength(displayName) > 96 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Policy definition metadata is invalid.')
    end
    local ruleCount = arrayLength(definition.rules or {}, 64)
    if ruleCount == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Policy rules must be a bounded dense array.')
    end
    local sanitized = {
        display_name = displayName,
        default_effect = defaultEffect,
        status = status,
        rules = {}
    }
    local seen = {}
    for index = 1, ruleCount do
        local rule = definition.rules[index]
        valid, validationError = closedObject(rule, {
            key = true, priority = true, effect = true, action = true,
            subject_kind = true, scope = true, scope_ref = true, condition = true
        }, 'Policy rule')
        if not valid then return nil, validationError end
        local key = rule.key or ('rule_' .. tostring(index))
        local priority = rule.priority or 0
        local effect = rule.effect
        local actionPattern = rule.action or action
        local subjectKind = rule.subject_kind or 'character'
        local scope = rule.scope or 'group'
        local scopeRef = rule.scope_ref or ''
        if type(key) ~= 'string' or #key < 2 or #key > 64
            or not key:match('^[a-z][a-z0-9_.:%-]*$') or seen[key]
            or type(priority) ~= 'number' or math.type(priority) ~= 'integer'
            or priority < -32768 or priority > 32767
            or not POLICY_EFFECTS[effect] or not POLICY_SUBJECTS[subjectKind]
            or not POLICY_SCOPES[scope] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A policy rule contains invalid identity, priority, effect, subject, or scope data.')
        end
        seen[key] = true
        if type(actionPattern) ~= 'string' or #actionPattern < 3 or #actionPattern > 128
            or not actionPattern:match('^[a-z][a-z0-9_.%-]*%.?%*?$')
            or actionPattern:find('*', 1, true)
                and actionPattern:sub(-2) ~= '.*' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A policy rule action pattern is invalid.')
        end
        if type(scopeRef) ~= 'string' or #scopeRef > 128
            or (scope == 'global' or scope == 'group') and scopeRef ~= ''
            or scope ~= 'global' and scope ~= 'group' and #scopeRef < 1 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A policy rule scope reference is invalid.')
        end
        local condition, conditionError = validatePolicyCondition(rule.condition)
        if conditionError then return nil, conditionError end
        sanitized.rules[index] = {
            key = key,
            priority = priority,
            effect = effect,
            action = actionPattern,
            subject_kind = subjectKind,
            scope = scope,
            scope_ref = scopeRef,
            condition = condition
        }
    end
    table.sort(sanitized.rules, function(left, right)
        if left.priority ~= right.priority then return left.priority > right.priority end
        if left.effect ~= right.effect then return left.effect == 'deny' end
        return left.key < right.key
    end)
    return sanitized, nil
end

local function actionMatches(pattern, action)
    if pattern == action then return true end
    if pattern:sub(-2) ~= '.*' then return false end
    local prefix = pattern:sub(1, -3)
    return action:sub(1, #prefix + 1) == prefix .. '.'
end

local function scalarEquals(left, right)
    return type(left) == type(right) and left == right
end

local function definitionCache(runtime)
    local cache = type(runtime) == 'table' and runtime.definitionCache or nil
    if type(cache) ~= 'table' or type(cache.get) ~= 'function'
        or type(cache.put) ~= 'function' or type(cache.invalidate) ~= 'function' then
        return nil
    end
    return cache
end

local function policyCacheIdentity(groupId, action)
    return groupId .. ':' .. action
end

local function invalidatePolicy(runtime, groupId, action)
    local cache = definitionCache(runtime)
    if cache == nil then return 0 end
    return cache:invalidate('policy_rules', policyCacheIdentity(groupId, action))
end

local function evaluateCondition(tx, condition, parameters, actorMembership,
    targetMembership, evaluationContext)
    if not condition then return true, 'CONDITION_EMPTY' end
    if condition.target_active ~= nil then
        local actual = targetMembership ~= nil
            and targetMembership.lifecycle_state == 'ACTIVE'
        if actual ~= condition.target_active then return false, 'TARGET_STATE_MISMATCH' end
    end
    if condition.actor_rank_above_target ~= nil then
        if not targetMembership then return false, 'TARGET_REQUIRED' end
        if not evaluationContext.ranksLoaded then
            evaluationContext.ranksLoaded = true
            evaluationContext.ranks = tx.one([[SELECT
                actor_grade.rank_value AS actor_rank,
                target_grade.rank_value AS target_rank
            FROM synex_group_memberships AS actor_membership
            LEFT JOIN synex_group_membership_grades AS actor_assigned
                ON actor_assigned.membership_id = actor_membership.id
            LEFT JOIN synex_group_grades AS actor_grade ON actor_grade.id = actor_assigned.grade_id
            INNER JOIN synex_group_memberships AS target
                ON target.id = ? AND target.group_id = actor_membership.group_id
            LEFT JOIN synex_group_membership_grades AS target_assigned
                ON target_assigned.membership_id = target.id
            LEFT JOIN synex_group_grades AS target_grade ON target_grade.id = target_assigned.grade_id
            WHERE actor_membership.id = ?]], { targetMembership.id, actorMembership.id })
        end
        local ranks = evaluationContext.ranks
        local actual = ranks ~= nil and tonumber(ranks.actor_rank) ~= nil
            and tonumber(ranks.target_rank) ~= nil
            and tonumber(ranks.actor_rank) > tonumber(ranks.target_rank)
        if actual ~= condition.actor_rank_above_target then
            return false, 'GRADE_AUTHORITY_MISMATCH'
        end
    end
    if condition.parameter ~= nil then
        local actual = parameters and parameters[condition.parameter] or nil
        local matched
        if condition.operator == 'exists' then
            matched = actual ~= nil
        elseif condition.operator == 'equals' then
            matched = scalarEquals(actual, condition.value)
        elseif condition.operator == 'not_equals' then
            matched = not scalarEquals(actual, condition.value)
        else
            matched = false
            for _, candidate in ipairs(condition.value) do
                if scalarEquals(actual, candidate) then matched = true break end
            end
        end
        if not matched then return false, 'PARAMETER_CONDITION_MISMATCH' end
    end
    return true, 'CONDITION_MATCHED'
end

local function evaluateStoredPolicy(tx, input, runtime)
    if type(input) ~= 'table' or type(input.group_id) ~= 'string'
        or type(input.action) ~= 'string' or #input.action < 3 or #input.action > 96
        or not input.action:match('^[a-z][a-z0-9_.%-]*$')
        or type(input.actor_membership) ~= 'table'
        or type(input.actor_membership.id) ~= 'number'
        or input.actor_membership.id % 1 ~= 0 or input.actor_membership.id < 1 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Stored policy evaluation input is invalid.')
    end
    local group, groupError = activeGroup(tx, runtime, input.group_id, false)
    if not group then return nil, groupError end
    if input.target_membership ~= nil then
        if type(input.target_membership) ~= 'table'
            or input.target_membership.group_id ~= group.id then
            return nil, Foundation.domainError('INVALID_SCOPE',
                'The policy target membership belongs to another group.')
        end
    end
    local policy = tx.one([[SELECT id, public_id, default_effect, version
        FROM synex_group_policies
        WHERE group_id = ? AND policy_key = ? AND status = 'active']],
        { group.id, input.action })
    if not policy then
        invalidatePolicy(runtime, input.group_id, input.action)
        return {
            configured = false,
            decision = 'ALLOW',
            reason = 'NO_POLICY',
            trace = {}
        }, nil
    end
    local policyVersion = tonumber(policy.version)
    if policyVersion == nil or math.type(policyVersion) ~= 'integer'
        or policyVersion < 1 then
        invalidatePolicy(runtime, input.group_id, input.action)
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The stored policy revision is invalid.', true)
    end
    local cache = definitionCache(runtime)
    local identity = policyCacheIdentity(input.group_id, input.action)
    local rules = cache and cache:get('policy_rules', identity, policyVersion) or nil
    if rules == nil then
        rules = tx.many([[SELECT rule_key, priority, effect, action_pattern,
                subject_kind, scope_kind, scope_ref, condition_json
            FROM synex_group_policy_rules
            WHERE policy_id = ?
            ORDER BY priority DESC, effect ASC, rule_key ASC LIMIT 65]], { policy.id })
        if type(rules) ~= 'table' or #rules > 64
            or arrayLength(rules, 64) == nil then
            invalidatePolicy(runtime, input.group_id, input.action)
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The policy exceeds its supported rule bound.', true)
        end
        if cache ~= nil then
            local stored = cache:put('policy_rules', identity, policyVersion, rules)
            if not stored then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'The policy definition cache rejected a bounded definition.', true)
            end
        end
    elseif type(rules) ~= 'table' or #rules > 64
        or arrayLength(rules, 64) == nil then
        invalidatePolicy(runtime, input.group_id, input.action)
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The policy exceeds its supported rule bound.', true)
    end
    local matchedAllow, matchedDeny, policyTrace = false, false, {}
    local evaluationContext = { ranksLoaded = false }
    local requestedScope = input.scope or 'group'
    for _, rule in ipairs(rules) do
        local scopeMatches = rule.scope_kind == 'global'
            or rule.scope_kind == 'group'
                and (requestedScope == 'group' or requestedScope == 'subtree')
            or rule.scope_kind == requestedScope
                and type(input.parameters) == 'table'
                and input.parameters.scope_ref == rule.scope_ref
        local matched = actionMatches(rule.action_pattern, input.action)
            and (rule.subject_kind == 'character' or rule.subject_kind == 'membership')
            and scopeMatches
        local matchReason = matched and 'RULE_MATCHED' or 'RULE_CONTEXT_MISMATCH'
        if matched and rule.condition_json ~= nil then
            local decodedOk, decoded = pcall(runtime.jsonDecode, rule.condition_json)
            if not decodedOk then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'A stored policy condition is invalid.', true)
            end
            local condition, conditionError = validatePolicyCondition(decoded)
            if not condition then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    conditionError and conditionError.message
                        or 'A stored policy condition is invalid.', true)
            end
            local conditionMatched
            conditionMatched, matchReason = evaluateCondition(
                tx, condition, input.parameters or {},
                input.actor_membership, input.target_membership, evaluationContext)
            matched = matched and conditionMatched
        end
        if matched and rule.effect == 'deny' then matchedDeny = true end
        if matched and rule.effect == 'allow' then matchedAllow = true end
        policyTrace[#policyTrace + 1] = {
            layer = 'policy',
            sourceId = policy.public_id,
            ruleId = rule.rule_key,
            effect = rule.effect,
            matched = matched,
            reason = matchReason
        }
    end
    local decision, decisionReason
    if matchedDeny then
        decision, decisionReason = 'DENY', 'POLICY_EXPLICIT_DENY'
    elseif matchedAllow or policy.default_effect == 'allow' then
        decision, decisionReason = 'ALLOW', 'POLICY_ALLOWED'
    else
        decision, decisionReason = 'DENY', 'POLICY_DEFAULT_DENY'
    end
    local revision = tx.one([[SELECT version FROM synex_group_policies
        WHERE id = ? AND status = 'active']], { policy.id })
    if not revision or tonumber(revision.version) ~= policyVersion then
        invalidatePolicy(runtime, input.group_id, input.action)
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The policy changed while it was being evaluated.', true)
    end
    return {
        configured = true,
        policy_id = policy.public_id,
        decision = decision,
        reason = decisionReason,
        trace = policyTrace
    }, nil
end

handlers.evaluateStoredPolicy = evaluateStoredPolicy

function handlers.execute.policies_set(tx, request, runtime, context)
    if #request.action > 64 or not request.action:match('^[a-z][a-z0-9_.%-]*$') then
        return rejected('VALIDATION_FAILED',
            'Policy action must be a lowercase capability-like name of at most 64 characters.')
    end
    local _, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.policies.manage', 'group')
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = activeGroup(tx, runtime, request.group_id, true)
    if not group then return nil, groupError end
    local definition, definitionError = validatePolicyDefinition(
        request.action, request.definition)
    if not definition then return nil, definitionError end

    local existing = tx.one([[SELECT id, public_id, status, version
        FROM synex_group_policies
        WHERE group_id = ? AND policy_key = ? FOR UPDATE]], { group.id, request.action })
    local policyId, internalId, version
    if existing then
        version = tonumber(existing.version)
        if request.expected_version == nil or version ~= request.expected_version then
            return rejected('CONCURRENT_MODIFICATION',
                'Updating a policy requires its current expected_version.', true)
        end
        if tx.affected([[UPDATE synex_group_policies
                SET display_name = ?, status = ?, default_effect = ?, version = version + 1
                WHERE id = ? AND version = ?]], {
            definition.display_name, definition.status, definition.default_effect,
            existing.id, version
        }) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The policy changed while it was being updated.', true)
        end
        tx.query('DELETE FROM synex_group_policy_rules WHERE policy_id = ?', { existing.id })
        policyId, internalId, version = existing.public_id, existing.id, version + 1
    else
        if request.expected_version ~= nil and request.expected_version ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A new policy can only use expected_version 1.', true)
        end
        local id, idError = publicId(runtime, 'group_policy')
        if not id then return nil, idError end
        internalId = tx.insert([[INSERT INTO synex_group_policies
            (public_id, group_id, policy_key, display_name, status, default_effect, version)
            VALUES (?, ?, ?, ?, ?, ?, 1)]], {
            id, group.id, request.action, definition.display_name,
            definition.status, definition.default_effect
        })
        policyId, version = id, 1
    end
    for _, rule in ipairs(definition.rules) do
        local conditionJson
        if rule.condition ~= nil then
            conditionJson, definitionError = canonical(runtime, rule.condition)
            if not conditionJson then return nil, definitionError end
        end
        tx.query([[INSERT INTO synex_group_policy_rules
            (policy_id, rule_key, priority, effect, action_pattern,
             subject_kind, scope_kind, scope_ref, condition_json, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)]], {
            internalId, rule.key, rule.priority, rule.effect, rule.action,
            rule.subject_kind, rule.scope, rule.scope_ref, conditionJson
        })
    end
    local touched, touchError = runtime.touchGroup(tx, group.id)
    if not touched then return nil, touchError end
    invalidatePolicy(runtime, request.group_id, request.action)
    local response = runtime.success(policyId, 'policy', definition.status, version)
    return response, nil, {
        runtime.effect('policy.changed', 'policy', policyId, request.group_id,
            request.actor_character_id,
            existing and { status = existing.status, version = version - 1 } or nil,
            { action = request.action, status = definition.status, version = version },
            request.reason, version)
    }
end

function handlers.read.policies_simulate(tx, request, runtime, context)
    if #request.action > 64 or not request.action:match('^[a-z][a-z0-9_.%-]*$') then
        return rejected('VALIDATION_FAILED',
            'Policy action must be a lowercase capability-like name of at most 64 characters.')
    end
    local evaluation, evaluationError = runtime.evaluateCharacter(
        tx, request.group_id, request.actor_character_id,
        request.action, 'group', false)
    if not evaluation then return nil, evaluationError end
    local group, groupError = activeGroup(tx, runtime, request.group_id, false)
    if not group then return nil, groupError end

    local target
    if request.target_membership_id ~= nil then
        target, evaluationError = runtime.requireMembership(
            tx, request.target_membership_id, false)
        if not target then return nil, evaluationError end
        if target.group_id ~= group.id then
            return rejected('INVALID_SCOPE',
                'The simulated target membership belongs to another group.')
        end
    end
    local stored, storedError = evaluateStoredPolicy(tx, {
        group_id = request.group_id,
        action = request.action,
        actor_membership = evaluation.membership,
        target_membership = target,
        parameters = request.parameters or {},
        scope = 'group'
    }, runtime)
    if not stored then return nil, storedError end
    local policyTrace = stored.trace
    local override
    if not evaluation.allowed then
        override = { decision = 'DENY', reason = evaluation.reason }
    elseif stored.configured then
        override = { decision = stored.decision, reason = stored.reason }
    end
    local capabilityRequest = {
        actor_character_id = request.actor_character_id,
        group_id = request.group_id,
        action = request.action,
        scope = 'group'
    }
    return capabilityResult(capabilityRequest, context, evaluation, policyTrace, override), nil
end

return handlers
end
