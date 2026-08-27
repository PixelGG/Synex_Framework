return function(Foundation)
local domainError = Foundation.domainError
local createDefinitionCache = require('server.persistence.definition_cache')(Foundation)

local function seconds(value)
    local number = tonumber(value)
    if not number then return nil end
    if number > 100000000000 then number = math.floor(number / 1000) end
    return math.floor(number)
end

local function ruleScope(groupId, kind, reference)
    if kind == nil or kind == 'group' then return { groupId = groupId, mode = 'group' } end
    if kind == 'subtree' then return { groupId = groupId, mode = 'subtree' } end
    if kind == 'custom' and reference == 'subtree' then
        return { groupId = groupId, mode = 'subtree' }
    end
    return { groupId = groupId, scopeKind = kind, scopeRef = reference }
end

local function requestScope(groupId, scope)
    if type(scope) == 'table' then
        local ok, copied = pcall(Foundation.copyPlain, scope)
        if ok then
            copied.groupId = copied.groupId or groupId
            return copied
        end
    end
    return ruleScope(groupId, scope == 'subtree' and 'subtree' or 'group', '')
end

local function create(deps)
    local evaluator = assert(type(deps) == 'table'
        and type(deps.evaluator) == 'table'
        and type(deps.evaluator.evaluate) == 'function' and deps.evaluator,
        'groups capability access requires evaluator')
    local getStoredPolicyEvaluator = assert(
        type(deps.getStoredPolicyEvaluator) == 'function'
            and deps.getStoredPolicyEvaluator,
        'groups capability access requires getStoredPolicyEvaluator')
    local getRuntime = assert(type(deps.getRuntime) == 'function' and deps.getRuntime,
        'groups capability access requires getRuntime')
    local definitionCache = deps.definitionCache or createDefinitionCache({ maximum = 256 })
    assert(type(definitionCache) == 'table'
        and type(definitionCache.get) == 'function'
        and type(definitionCache.put) == 'function'
        and type(definitionCache.invalidate) == 'function'
        and type(definitionCache.invalidateGroup) == 'function'
        and type(definitionCache.clear) == 'function'
        and type(definitionCache.snapshot) == 'function',
        'groups capability access requires a definition cache')

    local function cached(namespace, identity, revision, loader)
        local cacheOk, value = pcall(
            definitionCache.get, definitionCache, namespace, identity, revision)
        if not cacheOk then
            return nil, domainError('DATABASE_ERROR',
                'The Groups definition cache could not be read.', true)
        end
        if value ~= nil then return value, nil end
        local loaded, loadError = loader()
        if loaded == nil then return nil, loadError end
        local stored = definitionCache:put(namespace, identity, revision, loaded)
        if not stored then
            return nil, domainError('DATABASE_ERROR',
                'The Groups definition cache rejected a bounded definition.', true)
        end
        return loaded, nil
    end

    local function verifyRevision(tx, groupId, internalId, expected, lock)
        local revision = tx.one([[SELECT model_version
            FROM synex_group_read_model_versions WHERE group_id = ?]]
            .. (lock and ' FOR UPDATE' or ''), { internalId })
        local actual = tonumber(revision and revision.model_version)
        if actual == nil or math.type(actual) ~= 'integer' or actual < 1 then
            definitionCache:invalidateGroup(groupId)
            return nil, domainError('DATABASE_ERROR',
                'The group definition revision is unavailable.', true)
        end
        if actual ~= expected then
            definitionCache:invalidateGroup(groupId)
            return nil, domainError('CONCURRENT_MODIFICATION',
                'Group authority definitions changed while they were being evaluated.', true)
        end
        return true, nil
    end

    local function loadCapabilitySources(tx, groupId, characterId, lock)
        local membership = tx.one([[SELECT membership.id, membership.public_id,
                membership.version, profile.lifecycle_state,
                group_record.id AS group_internal_id,
                read_model.model_version AS definition_revision,
                grade.id AS grade_internal_id, grade.public_id AS grade_public_id
            FROM synex_group_memberships AS membership
            INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
            INNER JOIN synex_group_read_model_versions AS read_model
                ON read_model.group_id = group_record.id
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = membership.id
            LEFT JOIN synex_group_membership_grades AS assigned
                ON assigned.membership_id = membership.id
            LEFT JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
            WHERE group_record.public_id = ? AND profile.character_id = ?
                AND group_record.status = 'active' AND profile.lifecycle_state = 'ACTIVE']]
                .. (lock and ' FOR UPDATE' or ''), { groupId, characterId })
        if not membership then
            return nil, domainError('MEMBERSHIP_NOT_ACTIVE',
                'An active membership is required for this Groups operation.')
        end
        local definitionRevision = tonumber(membership.definition_revision)
        if definitionRevision == nil or math.type(definitionRevision) ~= 'integer'
            or definitionRevision < 1 then
            return nil, domainError('DATABASE_ERROR',
                'The group definition revision is invalid.', true)
        end

        local defaults, defaultsError = cached(
            'group_defaults', groupId, definitionRevision, function()
                local rows = tx.many([[SELECT capability.id,
                        capability.capability_pattern, capability.effect,
                        capability.scope_kind, capability.scope_ref,
                        capability.delegable
                    FROM synex_group_default_capabilities AS capability
                    WHERE capability.group_id = ?
                    ORDER BY capability.id ASC LIMIT 257]],
                    { membership.group_internal_id })
                if #rows > 256 then
                    return nil, domainError('READ_MODEL_TOO_LARGE',
                        'The group-default capability model exceeds its supported bound.')
                end
                local result = {}
                for _, row in ipairs(rows) do
                    result[#result + 1] = {
                        id = 'group:' .. tostring(row.id),
                        capability = row.capability_pattern,
                        effect = row.effect,
                        delegable = tonumber(row.delegable) == 1,
                        scope = ruleScope(groupId, row.scope_kind, row.scope_ref)
                    }
                end
                return result, nil
            end)
        if not defaults then return nil, defaultsError end

        local gradeRules = {}
        if membership.grade_internal_id then
            local gradeIdentity = groupId .. ':' .. membership.grade_public_id
            local loaded, gradeError = cached(
                'grade_rules', gradeIdentity, definitionRevision, function()
                    local rows = tx.many([[SELECT capability.id,
                            capability.capability_pattern, capability.effect,
                            capability.delegable,
                            COALESCE(scope.scope_kind, 'group') AS scope_kind,
                            COALESCE(scope.scope_ref, '') AS scope_ref
                        FROM synex_group_grade_capabilities AS capability
                        LEFT JOIN synex_group_grade_capability_scopes AS scope
                            ON scope.grade_capability_id = capability.id
                        WHERE capability.grade_id = ?
                        ORDER BY capability.id ASC LIMIT 257]],
                        { membership.grade_internal_id })
                    if #rows > 256 then
                        return nil, domainError('READ_MODEL_TOO_LARGE',
                            'The grade capability model exceeds its supported bound.')
                    end
                    local result = {}
                    for _, row in ipairs(rows) do
                        result[#result + 1] = {
                            id = 'grade:' .. tostring(row.id),
                            capability = row.capability_pattern,
                            effect = row.effect,
                            delegable = tonumber(row.delegable) == 1,
                            scope = ruleScope(groupId, row.scope_kind, row.scope_ref)
                        }
                    end
                    return result, nil
                end)
            if not loaded then return nil, gradeError end
            gradeRules = loaded
        end

        local roleIdentity = groupId .. ':' .. membership.public_id
        local roles, rolesError = cached(
            'role_sources', roleIdentity, definitionRevision, function()
                -- Cache every active assignment window. The evaluator applies
                -- the current clock on each call, so a hit cannot prolong an
                -- expired grant or suppress a newly valid cached source.
                local rows = tx.many([[SELECT
                        assignment.public_id AS assignment_public_id,
                        role.public_id AS role_public_id,
                        capability.id AS capability_id,
                        capability.capability_pattern, capability.effect,
                        capability.scope_kind, capability.scope_ref,
                        capability.delegable,
                        UNIX_TIMESTAMP(assignment.valid_from) AS valid_from_unix,
                        UNIX_TIMESTAMP(assignment.valid_until) AS valid_until_unix
                    FROM synex_group_membership_roles AS assignment
                    INNER JOIN synex_group_roles AS role ON role.id = assignment.role_id
                    LEFT JOIN synex_group_role_capabilities AS capability
                        ON capability.role_id = role.id
                    WHERE assignment.membership_id = ? AND assignment.status = 'active'
                        AND role.status = 'active'
                    ORDER BY assignment.id, capability.id LIMIT 257]],
                    { membership.id })
                if #rows > 256 then
                    return nil, domainError('READ_MODEL_TOO_LARGE',
                        'The role capability model exceeds its supported bound.')
                end
                local result, byAssignment = {}, {}
                for _, row in ipairs(rows) do
                    local source = byAssignment[row.assignment_public_id]
                    if not source then
                        source = {
                            id = row.assignment_public_id,
                            validFrom = seconds(row.valid_from_unix),
                            validUntil = seconds(row.valid_until_unix),
                            rules = {}
                        }
                        byAssignment[row.assignment_public_id] = source
                        result[#result + 1] = source
                    end
                    if row.capability_id then
                        source.rules[#source.rules + 1] = {
                            id = 'role:' .. tostring(row.capability_id),
                            capability = row.capability_pattern,
                            effect = row.effect,
                            delegable = tonumber(row.delegable) == 1,
                            scope = ruleScope(groupId, row.scope_kind, row.scope_ref)
                        }
                    end
                end
                return result, nil
            end)
        if not roles then return nil, rolesError end

        local delegationRows = tx.many([[SELECT delegation.public_id,
                delegation.capability_pattern, delegation.scope_kind, delegation.scope_ref,
                UNIX_TIMESTAMP(delegation.valid_from) AS valid_from_unix,
                UNIX_TIMESTAMP(delegation.valid_until) AS valid_until_unix
            FROM synex_group_delegations AS delegation
            WHERE delegation.grantee_membership_id = ? AND delegation.status = 'active'
                AND delegation.valid_from <= CURRENT_TIMESTAMP(6)
                AND delegation.valid_until > CURRENT_TIMESTAMP(6)
            ORDER BY delegation.id ASC LIMIT 65]], { membership.id })
        if #delegationRows > 64 then
            return nil, domainError('READ_MODEL_TOO_LARGE',
                'The delegation model exceeds its supported bound.')
        end
        local delegations = {}
        for _, row in ipairs(delegationRows) do
            delegations[#delegations + 1] = {
                id = row.public_id,
                validFrom = seconds(row.valid_from_unix),
                validUntil = seconds(row.valid_until_unix),
                rules = {{
                    id = 'delegation:' .. row.public_id,
                    capability = row.capability_pattern,
                    effect = 'allow',
                    delegable = false,
                    scope = ruleScope(groupId, row.scope_kind, row.scope_ref)
                }}
            }
        end

        local membershipRuleRows = tx.many([[SELECT capability.id,
                capability.capability_pattern, capability.effect,
                capability.scope_kind, capability.scope_ref, capability.delegable,
                UNIX_TIMESTAMP(capability.valid_from) AS valid_from_unix,
                UNIX_TIMESTAMP(capability.valid_until) AS valid_until_unix
            FROM synex_group_membership_capabilities AS capability
            WHERE capability.membership_id = ?
            ORDER BY capability.id ASC LIMIT 257]], { membership.id })
        if #membershipRuleRows > 256 then
            return nil, domainError('READ_MODEL_TOO_LARGE',
                'The membership capability model exceeds its supported bound.')
        end
        local membershipRules = {}
        for _, row in ipairs(membershipRuleRows) do
            membershipRules[#membershipRules + 1] = {
                id = 'membership:' .. tostring(row.id),
                capability = row.capability_pattern,
                effect = row.effect,
                delegable = tonumber(row.delegable) == 1,
                scope = ruleScope(groupId, row.scope_kind, row.scope_ref),
                validFrom = seconds(row.valid_from_unix),
                validUntil = seconds(row.valid_until_unix)
            }
        end

        local revisionValid, revisionError = verifyRevision(
            tx, groupId, membership.group_internal_id, definitionRevision, lock)
        if not revisionValid then return nil, revisionError end
        return {
            membership = membership,
            defaults = defaults,
            grade = membership.grade_public_id and {
                id = membership.grade_public_id, rules = gradeRules
            } or nil,
            membershipRules = {
                id = membership.public_id,
                rules = membershipRules
            },
            roles = roles,
            delegations = delegations
        }, nil
    end

    local function evaluateCharacter(tx, groupId, characterId, capability, scope, lock)
        local sources, sourceError = loadCapabilitySources(
            tx, groupId, characterId, lock)
        if not sources then return nil, sourceError end
        local evaluation, evaluationError = evaluator:evaluate({
            capability = capability,
            scope = requestScope(groupId, scope),
            defaults = sources.defaults,
            grade = sources.grade,
            roles = sources.roles,
            membership = sources.membershipRules,
            delegations = sources.delegations
        })
        if not evaluation then return nil, evaluationError end
        evaluation.membership = sources.membership
        return evaluation, nil
    end

    local function authorize(tx, groupId, characterId, capability, scope, policyContext)
        local evaluation, evaluationError = evaluateCharacter(
            tx, groupId, characterId, capability, scope, true)
        if not evaluation then return nil, evaluationError end
        if not evaluation.allowed then
            return nil, domainError('INSUFFICIENT_PERMISSION',
                'The actor character is not authorized for this Groups operation.', false, {
                    capability = capability,
                    reason = evaluation.reason
                })
        end
        local storedPolicyEvaluator = getStoredPolicyEvaluator()
        -- Policy administration is the recovery boundary: a stored policy must
        -- never be able to make every future policy repair impossible.
        if storedPolicyEvaluator ~= nil
            and capability ~= 'synex.groups.policies.manage' then
            local policy, policyError = storedPolicyEvaluator(tx, {
                group_id = groupId,
                action = capability,
                actor_membership = evaluation.membership,
                target_membership = policyContext and policyContext.target_membership or nil,
                parameters = policyContext and policyContext.parameters or nil,
                scope = scope or 'group'
            }, getRuntime())
            if not policy then return nil, policyError end
            evaluation.policy = policy
            if policy.decision == 'DENY' then
                return nil, domainError('INSUFFICIENT_PERMISSION',
                    'A Groups policy denied this operation.', false, {
                        capability = capability,
                        policy_id = policy.policy_id,
                        reason = policy.reason
                    })
            end
        end
        return evaluation.membership, nil, evaluation
    end

    return {
        authorize = authorize,
        evaluateCharacter = evaluateCharacter,
        definitionCache = definitionCache,
        invalidateDefinitions = function(groupId)
            return definitionCache:invalidateGroup(groupId)
        end,
        clearDefinitions = function()
            return definitionCache:clear()
        end,
        definitionCacheSnapshot = function()
            return definitionCache:snapshot()
        end
    }
end

return create
end
