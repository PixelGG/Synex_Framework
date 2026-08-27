return function(Foundation)
local reportUnexpectedError = Foundation.reportUnexpectedError
local responseCopyLimits = { maximumDepth = 12, maximumKeys = 4096, maximumStringBytes = 16384, preserveContainerKind = false }
-- Keep a safety margin below Core's 32 KiB service/RPC response ceiling. This
-- catches open-object read models (for example metadata) before they trip the
-- Core transport circuit breaker.
local MAXIMUM_READ_RESPONSE_BYTES = 30000
local Validation = require('server.validation')(Foundation)
local contractErrorCodes = {
    VALIDATION_FAILED = true,
    CHARACTER_NOT_FOUND = true,
    GROUP_NOT_FOUND = true,
    GROUP_TYPE_NOT_FOUND = true,
    GROUP_TYPE_INACTIVE = true,
    GROUP_TYPE_STATIC = true,
    STATIC_DEFINITION_REQUIRED = true,
    GROUP_EXISTS = true,
    GROUP_INACTIVE = true,
    GROUP_HAS_ACTIVE_CHILDREN = true,
    GROUP_HAS_ACTIVE_MEMBERS = true,
    GROUP_HAS_ACTIVE_RELATIONSHIPS = true,
    GROUP_HAS_ACTIVE_WORKFLOWS = true,
    GROUP_NOT_ARCHIVED = true,
    GROUP_DELETION_IN_PROGRESS = true,
    GROUP_DELETION_NOT_FOUND = true,
    DELETION_PLAN_CONFLICT = true,
    DELETION_PLAN_INVALID = true,
    CREATION_REQUEST_NOT_FOUND = true,
    CREATION_REQUEST_EXPIRED = true,
    CREATION_REQUEST_TERMINAL = true,
    CREATOR_CANNOT_DECIDE = true,
    APPROVAL_ALREADY_DECIDED = true,
    TYPE_OWNER_CONFLICT = true,
    PARENT_GROUP_NOT_FOUND = true,
    PARENT_GROUP_INACTIVE = true,
    MEMBERSHIP_NOT_FOUND = true,
    MEMBERSHIP_ALREADY_EXISTS = true,
    MEMBERSHIP_NOT_ACTIVE = true,
    GRADE_NOT_FOUND = true,
    ROLE_NOT_FOUND = true,
    RELATIONSHIP_INVALID = true,
    RELATIONSHIPS_DISABLED = true,
    RELATIONSHIP_TYPE_NOT_FOUND = true,
    RELATIONSHIP_TYPE_INACTIVE = true,
    RELATIONSHIP_EXISTS = true,
    RELATIONSHIP_CYCLE = true,
    RELATIONSHIP_GRAPH_TOO_DEEP = true,
    RELATIONSHIP_NOT_FOUND = true,
    ASSIGNMENT_NOT_FOUND = true,
    DUTY_SESSION_NOT_FOUND = true,
    HIERARCHY_CYCLE = true,
    HIERARCHY_DISABLED = true,
    HIERARCHY_INVALID = true,
    HIERARCHY_DEPTH_EXCEEDED = true,
    REPORTING_CYCLE = true,
    INSUFFICIENT_PERMISSION = true,
    INVALID_SCOPE = true,
    INVALID_TRANSITION = true,
    TARGET_GRADE_TOO_HIGH = true,
    ROLE_EXCLUSIVE_CONFLICT = true,
    MEMBER_LIMIT_REACHED = true,
    GRADE_CAPACITY_REACHED = true,
    GRADE_EXISTS = true,
    GRADE_IN_USE = true,
    ROLE_EXISTS = true,
    ROLE_IN_USE = true,
    CAPABILITY_SOURCE_INACTIVE = true,
    ATTRIBUTE_NOT_FOUND = true,
    READ_MODEL_TOO_LARGE = true,
    APPROVAL_REQUIRED = true,
    CONCURRENT_MODIFICATION = true,
    IDEMPOTENCY_CONFLICT = true,
    OPERATION_IN_PROGRESS = true,
    HOOK_REJECTED = true,
    DATABASE_RESULT_INVALID = true, DATABASE_ERROR = true
}
local mutationHooks = {
    create = 'before_group_create',
    update = 'before_group_update',
    archive = 'before_group_archive',
    delete = 'before_group_delete',
    members_invite = 'before_membership_invite',
    members_accept = 'before_membership_activate',
    members_set_visibility = 'before_membership_visibility_change',
    members_set_grade = 'before_grade_change', compatibility_set_primary_grade = 'before_grade_change',
    roles_assign = 'before_role_assignment',
    roles_remove = 'before_role_removal',
    duty_start = 'before_duty_start',
    duty_stop = 'before_duty_end',
    relationships_create = 'before_relationship_change',
    relationships_update = 'before_relationship_change',
    delegations_create = 'before_delegation',
    delegations_revoke = 'before_delegation',
    policies_set = 'before_policy_change',
    members_transition_policy_set = 'before_policy_change'
}
local terminalMembershipStates = {
    TERMINATED = true,
    BANNED = true,
    LEFT = true,
    ARCHIVED = true
}
local approvedTargetOperations = {
    ['group.update'] = 'update',
    ['group.archive'] = 'archive',
    ['membership.transition'] = 'members_transition',
    ['membership.set_grade'] = 'members_set_grade', ['membership.set_primary_grade'] = 'compatibility_set_primary_grade',
    ['role.assign'] = 'roles_assign',
    ['role.remove'] = 'roles_remove',
    ['policy.set'] = 'policies_set',
    ['relationship.update'] = 'relationships_update'
}
local hookCopyLimits = {
    maximumDepth = 12,
    maximumKeys = 512,
    maximumStringBytes = 16384,
    preserveContainerKind = true
}
-- Hooks may refine descriptions but cannot redirect an authorized actor,
-- aggregate, lifecycle route, or CAS revision. Approved payloads stay immutable.
local immutableHookFields = {
    create = { 'idempotency_key', 'actor_character_id', 'type', 'slug', 'parent_group_id', 'status', 'dynamic', 'visibility' },
    update = { 'idempotency_key', 'actor_character_id', 'group_id', 'expected_version', 'status', 'parent_group_id', 'visibility' },
    archive = { 'idempotency_key', 'actor_character_id', 'group_id', 'expected_version' },
    delete = { 'idempotency_key', 'actor_character_id', 'group_id', 'expected_version' },
    members_invite = { 'idempotency_key', 'actor_character_id', 'group_id', 'character_id', 'grade_id', 'role_ids' },
    members_accept = { 'idempotency_key', 'actor_character_id', 'invitation_id' },
    members_transition = { 'idempotency_key', 'actor_character_id', 'membership_id', 'expected_version', 'status' },
    members_transition_policy_set = { 'idempotency_key', 'actor_character_id', 'group_id', 'from_status', 'to_status',
        'expected_version', 'allowed', 'required_capability', 'approval_required', 'reason_required' },
    members_set_grade = { 'idempotency_key', 'actor_character_id', 'membership_id', 'grade_id', 'expected_version' }, compatibility_set_primary_grade = { 'idempotency_key', 'actor_character_id', 'membership_id', 'grade_id', 'expected_version', 'group_type', 'expected_primary_version' },
    members_set_visibility = { 'idempotency_key', 'actor_character_id', 'membership_id', 'visibility', 'expected_version' },
    roles_assign = { 'idempotency_key', 'actor_character_id', 'membership_id', 'role_id' },
    roles_remove = { 'idempotency_key', 'actor_character_id', 'membership_role_id', 'expected_version' },
    duty_start = { 'idempotency_key', 'actor_character_id', 'membership_id', 'state', 'assignment_id' },
    duty_stop = { 'idempotency_key', 'actor_character_id', 'duty_session_id', 'expected_version' },
    relationships_create = { 'idempotency_key', 'actor_character_id', 'source_group_id', 'target_group_id', 'relation_type' },
    relationships_update = { 'idempotency_key', 'actor_character_id', 'relationship_id', 'expected_version', 'status' },
    delegations_create = { 'idempotency_key', 'actor_character_id', 'group_id', 'grantee_membership_id', 'capability',
        'scope', 'valid_from', 'valid_until' },
    delegations_revoke = { 'idempotency_key', 'actor_character_id', 'delegation_id', 'expected_version' },
    applications_review = { 'idempotency_key', 'actor_character_id', 'application_id', 'expected_version', 'decision' },
    policies_set = { 'idempotency_key', 'actor_character_id', 'group_id', 'expected_version', 'action', 'definition' }
}
local readOperations = {
    get = true,
    list = true,
    creation_requests_get = true,
    relationships_get = true,
    relationships_list = true,
    members_transition_policy_get = true,
    members_get = true,
    members_list = true,
    capabilities_check = true,
    capabilities_explain = true,
    duty_list = true,
    assignments_get = true,
    assignments_list = true,
    policies_simulate = true,
    attributes_get = true,
    directory_list = true,
    history_list = true,
    self_snapshot = true,
    compatibility_snapshot = true, compatibility_resolve_target = true,
    doctor = true
}
local function normalizeCoreResult(value, err)
    if value == false and type(err) == 'table' then return nil, err end
    return value, err
end
local function contractError(candidate, fallbackCode, fallbackMessage, fallbackRetryable)
    local candidateCode = type(candidate) == 'table' and candidate.code or nil
    local declared = contractErrorCodes[candidateCode] == true
    local code = declared and candidateCode or fallbackCode
    local message = declared and candidate.message or fallbackMessage
    if type(message) ~= 'string' or #message < 1 or #message > 512
        or message:find('[%z\1-\31\127]') then
        message = fallbackMessage
    end
    local details
    if declared and candidate.details ~= nil then
        local copied, bounded = pcall(Foundation.copyPlain, candidate.details, {
            maximumDepth = 5,
            maximumKeys = 32,
            maximumStringBytes = 512,
            preserveContainerKind = false
        })
        if copied then details = bounded end
    end
    return Foundation.domainError(code, message,
        declared and candidate.retryable == true or not declared and fallbackRetryable == true,
        details)
end
local function validContext(context)
    return type(context) == 'table'
        and type(context.traceId) == 'string' and #context.traceId >= 8 and #context.traceId <= 64
        and context.traceId:match('^[A-Za-z0-9_.:%-]+$') ~= nil
        and type(context.caller) == 'string' and #context.caller >= 3 and #context.caller <= 64
        and context.caller:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
        and type(context.callerEpoch) == 'number'
        and math.type(context.callerEpoch) == 'integer' and context.callerEpoch >= 1
end
local function createService(deps)
    local repository = assert(type(deps.repository) == 'table' and deps.repository,
        'synex_groups service requires deps.repository')
    local characters = assert(type(deps.characters) == 'table'
        and Foundation.isCallable(deps.characters.get) and deps.characters,
        'synex_groups service requires deps.characters')
    local hooks = assert(type(deps.hooks) == 'table'
        and Foundation.isCallable(deps.hooks.run) and deps.hooks,
        'synex_groups service requires deps.hooks')
    local audit = assert(type(deps.audit) == 'table'
        and Foundation.isCallable(deps.audit.append) and deps.audit,
        'synex_groups service requires deps.audit')
    local cache = assert(type(deps.cache) == 'table' and deps.cache,
        'synex_groups service requires deps.cache')
    local errorSink = assert(Foundation.isCallable(deps.errorSink) and deps.errorSink,
        'synex_groups service requires deps.errorSink')
    local jsonEncode = assert(Foundation.isCallable(deps.jsonEncode) and deps.jsonEncode,
        'synex_groups service requires deps.jsonEncode')
    local runtimeEffects = assert(type(deps.runtimeEffects) == 'table'
        and Foundation.isCallable(deps.runtimeEffects.apply) and deps.runtimeEffects,
        'synex_groups service requires deps.runtimeEffects')
    local groupDeletions = deps.groupDeletions
    if groupDeletions ~= nil and (type(groupDeletions) ~= 'table'
        or not Foundation.isCallable(groupDeletions.advance)) then
        error('synex_groups service requires a callable group deletion coordinator')
    end
    local groupCreationApprovals = deps.groupCreationApprovals
    if groupCreationApprovals ~= nil and (type(groupCreationApprovals) ~= 'table'
        or not Foundation.isCallable(groupCreationApprovals.advance)) then
        error('synex_groups service requires a callable group creation approval coordinator')
    end
    local function emitError(event)
        pcall(errorSink, event)
    end
    local function verifyCharacters(request)
        local identifiers, seen = {}, {}
        for _, field in ipairs({ 'actor_character_id', 'character_id' }) do
            local characterId = request[field]
            if characterId ~= nil and not seen[characterId] then
                if not Foundation.isPublicId(characterId) then
                    return nil, Foundation.domainError('VALIDATION_FAILED', field .. ' is invalid.')
                end
                seen[characterId] = true
                identifiers[#identifiers + 1] = characterId
            end
        end
        table.sort(identifiers)
        for _, characterId in ipairs(identifiers) do
            local character, characterError = normalizeCoreResult(characters.get(characterId))
            if not character then
                if characterError and characterError.code ~= 'CHARACTER_NOT_FOUND' then
                    return nil, contractError(characterError, 'DATABASE_ERROR',
                        'Character verification is temporarily unavailable.', true)
                end
                return nil, Foundation.domainError('CHARACTER_NOT_FOUND',
                    'The referenced character does not exist.')
            end
        end
        return true, nil
    end
    local function runNamedHook(suffix, request, context, operation)
        local called, result, hookError = pcall(hooks.run,
            'synex.groups.' .. suffix,
            request,
            {
                traceId = context.traceId,
                metadata = { caller = context.caller, operation = operation }
            })
        if not called then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'A Groups policy hook could not be evaluated.', true)
        end
        result, hookError = normalizeCoreResult(result, hookError)
        if result == nil then
            return nil, contractError(hookError, 'HOOK_REJECTED',
                'A Groups policy hook rejected the operation.', false)
        end
        local copied, candidate = pcall(Foundation.copyPlain, result, hookCopyLimits)
        if not copied then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'A Groups policy hook returned an invalid patch.')
        end
        return candidate, nil, true
    end
    local function sameJsonValue(left, right, depth)
        if type(left) ~= type(right) then return false end
        if type(left) ~= 'table' then return left == right end
        depth = (depth or 0) + 1
        if depth > 12 then return false end
        if Foundation.jsonContainerKind(left) ~= Foundation.jsonContainerKind(right) then
            return false
        end
        local leftCount, rightCount = 0, 0
        for key, value in pairs(left) do
            leftCount = leftCount + 1
            if not sameJsonValue(value, rawget(right, key), depth) then return false end
        end
        for _ in pairs(right) do rightCount = rightCount + 1 end
        return leftCount == rightCount
    end
    local function hookSuffix(operation, request)
        if operation == 'members_transition' then
            local target = type(request.status) == 'string' and request.status:upper() or nil
            if target == 'ACTIVE' then return 'before_membership_activate' end
            if target == 'SUSPENDED' then return 'before_membership_suspend' end
            if terminalMembershipStates[target] then return 'before_membership_terminate' end
            return 'before_membership_transition'
        end
        if operation == 'applications_review' then
            local decision = type(request.decision) == 'string' and request.decision:lower() or nil
            if decision == 'approved' then return 'before_membership_activate' end
            return nil
        end
        return mutationHooks[operation]
    end
    local function routingUnchanged(operation, before, after)
        for _, field in ipairs(immutableHookFields[operation] or {}) do
            if not sameJsonValue(rawget(before, field), rawget(after, field)) then
                return false
            end
        end
        return true
    end
    local function runHook(operation, request, context)
        local suffix = hookSuffix(operation, request)
        if not suffix then return request, nil, false end
        local copied, original = pcall(Foundation.copyPlain, request, hookCopyLimits)
        if not copied then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'A Groups policy hook received an invalid request.')
        end
        local candidate, hookError, hookRan = runNamedHook(
            suffix, request, context, operation)
        if not candidate then return nil, hookError end
        if not routingUnchanged(operation, original, candidate) then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'A Groups policy hook cannot alter security-sensitive routing fields.')
        end
        return candidate, nil, hookRan
    end
    local function runApprovedHooks(envelope, context)
        local copied, approved = pcall(Foundation.copyPlain, envelope, {
            maximumDepth = 12,
            maximumKeys = 256,
            maximumStringBytes = 4096,
            preserveContainerKind = true
        })
        if not copied or type(approved) ~= 'table'
            or type(approved.action) ~= 'string' or type(approved.payload) ~= 'table' then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'The approved Groups operation envelope is invalid.')
        end
        local targetOperation = approvedTargetOperations[approved.action]
        local targetHook = targetOperation and hookSuffix(targetOperation, approved.payload) or nil
        if type(targetOperation) ~= 'string' or type(targetHook) ~= 'string' then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'The approved Groups operation has no exact target hook.')
        end
        local proposalCandidate, proposalError = runNamedHook(
            'before_proposal_execute', envelope, context, 'proposal_execute')
        if not proposalCandidate then return nil, proposalError end
        if not sameJsonValue(approved, proposalCandidate) then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'The proposal execution hook cannot alter approved content.')
        end
        local targetCandidate, targetError = runNamedHook(
            targetHook, approved.payload, context, targetOperation)
        if not targetCandidate then return nil, targetError end
        if not sameJsonValue(approved.payload, targetCandidate) then
            return nil, Foundation.domainError('HOOK_REJECTED',
                'The target operation hook cannot alter approved content.')
        end
        return approved, nil, true
    end
    local function appendCoreAudit(effect, context)
        local entry = type(effect) == 'table' and effect.audit or nil
        if type(entry) ~= 'table' or type(entry.action) ~= 'string'
            or type(entry.targetType) ~= 'string' or type(entry.targetId) ~= 'string' then
            return true
        end
        local entryCopied, boundaryEntry = pcall(Foundation.copyPlain, entry, {
            maximumDepth = 12,
            maximumKeys = 512,
            maximumStringBytes = 16384,
            preserveContainerKind = false
        })
        if not entryCopied then
            emitError({ operation = 'core_audit_forward', traceId = context.traceId,
                code = 'AUDIT_ENTRY_INVALID' })
            return false
        end
        local appendCalled, appended, appendError = pcall(audit.append, {
            action = boundaryEntry.action,
            targetType = boundaryEntry.targetType,
            targetId = boundaryEntry.targetId,
            traceId = context.traceId,
            before = boundaryEntry.before,
            after = boundaryEntry.after,
            context = {
                actorCharacterId = boundaryEntry.actorCharacterId,
                caller = context.caller,
                reason = boundaryEntry.reason
            }
        })
        if not appendCalled then
            emitError({ operation = 'core_audit_forward', traceId = context.traceId,
                code = 'AUDIT_FORWARD_FAILED' })
            return false
        end
        appended, appendError = normalizeCoreResult(appended, appendError)
        if not appended then
            emitError({ operation = 'core_audit_forward', traceId = context.traceId,
                code = appendError and appendError.code or 'AUDIT_FORWARD_FAILED' })
            return false
        end
        if effect.auditDeliveryId ~= nil and Foundation.isCallable(repository.markAuditDelivered) then
            local deliveryId = effect.auditDeliveryId
            local coreEventId = type(appended) == 'table' and appended.eventId or nil
            local validDeliveryId = type(deliveryId) == 'number'
                and math.type(deliveryId) == 'integer' and deliveryId >= 1
                or type(deliveryId) == 'string' and #deliveryId >= 8 and #deliveryId <= 64
            if not validDeliveryId or type(coreEventId) ~= 'string'
                or #coreEventId < 8 or #coreEventId > 64 then
                emitError({ operation = 'core_audit_acknowledge', traceId = context.traceId,
                    code = 'AUDIT_DELIVERY_INVALID' })
                return false
            end
            local deliveryCalled, delivered, deliveryError = pcall(
                repository.markAuditDelivered,
                repository,
                deliveryId,
                coreEventId,
                {
                    traceId = context.traceId,
                    caller = context.caller,
                    callerEpoch = context.callerEpoch,
                    deadlineAt = context.deadlineAt
                }
            )
            if deliveryCalled then delivered, deliveryError = normalizeCoreResult(delivered, deliveryError) end
            if not deliveryCalled or not delivered then
                emitError({ operation = 'core_audit_acknowledge', traceId = context.traceId,
                    code = deliveryError and deliveryError.code or 'AUDIT_DELIVERY_ACK_FAILED' })
                return false
            end
        end
        return true
    end
    local function invalidate(effect)
        if type(effect) ~= 'table' then return end
        if type(effect.groupId) == 'string' then
            cache:invalidatePrefix('group:' .. effect.groupId)
            cache:invalidatePrefix('directory:' .. effect.groupId)
        end
        if type(effect.characterId) == 'string' then
            cache:invalidatePrefix('character:' .. effect.characterId)
        end
        if type(effect.membershipId) == 'string' then
            cache:invalidatePrefix('membership:' .. effect.membershipId)
        elseif type(effect.groupId) == 'string' or type(effect.characterId) == 'string' then
            -- Membership cache keys cannot otherwise be traced back to a group.
            -- Prefer a conservative invalidation over serving stale authority data.
            cache:invalidatePrefix('membership:')
        end
    end
    local function validateReadResponse(operation, value)
        if not readOperations[operation] then return true, nil end
        local encodedOk, encoded = pcall(jsonEncode, value)
        if not encodedOk or type(encoded) ~= 'string' then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The Groups read response could not be encoded.', true)
        end
        if #encoded > MAXIMUM_READ_RESPONSE_BYTES then
            return nil, Foundation.domainError('READ_MODEL_TOO_LARGE',
                'The Groups read response exceeds its supported transport bound.', false, {
                    maximum_bytes = MAXIMUM_READ_RESPONSE_BYTES
                })
        end
        return true, nil
    end
    local function invoke(operation, request, context)
        if type(request) ~= 'table' then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'Groups requests must be objects.')
        end
        if not validContext(context) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Groups operations require caller- and epoch-bound trace context.')
        end
        local copiedOk, candidate = pcall(Foundation.copyPlain, request, {
            preserveContainerKind = true
        })
        if not copiedOk then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'Groups requests must be bounded plain JSON data.')
        end
        if operation == 'self_snapshot' then
            local session = context.session
            if type(session) ~= 'table' or session.state ~= 'ACTIVE'
                or not Foundation.isSubjectId(session.characterId)
                or context.source ~= session.source
                or context.sourceGeneration ~= session.sourceGeneration then
                return nil, Foundation.domainError('SESSION_REQUIRED',
                    'An active character-bound Synex session is required.')
            end
            candidate.actor_character_id = session.characterId
        end
        local requestValid, requestError = Validation.operation(operation, candidate)
        if not requestValid then return nil, requestError end
        if context.idempotencyKey ~= nil and candidate.idempotency_key ~= nil
            and context.idempotencyKey ~= candidate.idempotency_key then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Request and service-context idempotency keys must match.')
        end
        local repositoryContext = {
            traceId = context.traceId,
            caller = context.caller,
            callerEpoch = context.callerEpoch,
            deadlineAt = context.deadlineAt,
            idempotencyKey = candidate.idempotency_key or context.idempotencyKey
        }
        -- Policy hooks are extension code and may have effects outside the
        -- Groups transaction.  Authenticate the exact actor/target route
        -- before invoking them, then let the mutation handler authorize again
        -- inside its authoritative transaction to close the write-side TOCTOU
        -- window.  Missing preflight support is intentionally fail-closed.
        if not readOperations[operation] then
            if not Foundation.isCallable(repository.preflight) then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'The Groups authorization preflight is unavailable.', true)
            end
            local preflighted, preflightError = repository:preflight(
                operation, candidate, repositoryContext)
            if not preflighted then
                return nil, contractError(preflightError, 'DATABASE_ERROR',
                    'The Groups authorization preflight could not be completed.', true)
            end
        end
        -- Caller-controlled character identifiers are resolved only after the
        -- exact mutation authority boundary.  Reads resolve identity through
        -- their repository authorization/visibility model; self_snapshot is
        -- the sole read whose character comes from an authenticated session.
        if not readOperations[operation] or operation == 'self_snapshot'
            or operation == 'compatibility_snapshot' or operation == 'compatibility_resolve_target' then
            local charactersValid, characterError = verifyCharacters(candidate)
            if not charactersValid then return nil, characterError end
        end
        local hookedCandidate, hookError, hookRan = runHook(operation, candidate, context)
        if not hookedCandidate then return nil, hookError end
        candidate = hookedCandidate
        if hookRan then
            local patchValid = Validation.operation(operation, candidate)
            if not patchValid then
                return nil, Foundation.domainError('HOOK_REJECTED',
                    'A Groups policy hook returned an invalid patch.')
            end
            if not readOperations[operation] then
                local patchedCharactersValid, patchedCharacterError = verifyCharacters(candidate)
                if not patchedCharactersValid then return nil, patchedCharacterError end
            end
        end
        local cacheKey
        if operation == 'get' then cacheKey = 'group:' .. candidate.group_id .. ':detail' end
        if operation == 'members_get' then cacheKey = 'membership:' .. candidate.membership_id end
        if operation == 'self_snapshot' then
            cacheKey = ('character:%s:self:%s:%s'):format(
                candidate.actor_character_id, candidate.cursor or 'first',
                tostring(candidate.limit or 10))
        end
        if operation == 'compatibility_snapshot' then
            cacheKey = ('character:%s:compatibility:%s:%s'):format(
                candidate.actor_character_id, candidate.cursor or 'first',
                tostring(candidate.limit or 8))
        end
        if cacheKey then
            local cached = cache:get(cacheKey)
            if cached then
                local cachedValid, cachedError = validateReadResponse(operation, cached)
                if not cachedValid then return nil, cachedError end
                return cached, nil
            end
        end
        local handler = readOperations[operation] and repository.read or repository.execute
        if not Foundation.isCallable(handler) then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The Groups repository operation is unavailable.', true)
        end
        repositoryContext.idempotencyKey = candidate.idempotency_key or context.idempotencyKey
        if operation == 'proposals_approve' then
            repositoryContext.beforeProposalExecute = function(envelope)
                return runApprovedHooks(envelope, context)
            end
        end
        local value, operationError, effects = handler(
            repository, operation, candidate, repositoryContext)
        if not value then
            return nil, contractError(operationError, 'DATABASE_ERROR',
                'The Groups operation could not be completed.', true)
        end
        local responseCopied, boundaryValue = pcall(
            Foundation.copyPlain, value, responseCopyLimits)
        if not responseCopied then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'The Groups operation returned invalid data.', true)
        end
        value = boundaryValue
        local responseValid, responseError = validateReadResponse(operation, value)
        if not responseValid then return nil, responseError end
        if cacheKey then cache:put(cacheKey, value) end
        for _, effect in ipairs(type(effects) == 'table' and effects or {}) do
            invalidate(effect)
            local runtimeCalled, runtimeApplied, runtimeError = pcall(
                runtimeEffects.apply, effect)
            if not runtimeCalled or runtimeApplied == false or runtimeApplied == nil then
                emitError({ operation = 'runtime_index_refresh', traceId = context.traceId,
                    code = runtimeCalled and type(runtimeError) == 'table'
                        and runtimeError.code or 'RUNTIME_INDEX_REFRESH_FAILED' })
            end
            appendCoreAudit(effect, context)
        end
        if operation == 'delete' then
            if not groupDeletions then
                emitError({ operation = 'group_deletion_advance', traceId = context.traceId,
                    code = 'DELETION_COORDINATOR_UNAVAILABLE' })
                return value, nil
            end
            local advancedOk, advanced, advanceError = pcall(
                groupDeletions.advance, groupDeletions, value.deletion_request_id)
            if advancedOk and advanced then
                local copiedOk, copied = pcall(
                    Foundation.copyPlain, advanced, responseCopyLimits)
                if copiedOk then return copied, nil end
            end
            emitError({ operation = 'group_deletion_advance', traceId = context.traceId,
                code = type(advanceError) == 'table'
                    and advanceError.code or 'DELETION_COORDINATOR_UNAVAILABLE' })
        end
        if operation == 'creation_requests_approve' and value.status == 'approved' then
            if not groupCreationApprovals then
                emitError({ operation = 'group_creation_advance', traceId = context.traceId,
                    code = 'CREATION_COORDINATOR_UNAVAILABLE' })
            else
                local advancedOk, advanced, advanceError = pcall(
                    groupCreationApprovals.advance, groupCreationApprovals,
                    value.creation_request_id, context.traceId)
                if not advancedOk or not advanced then
                    emitError({ operation = 'group_creation_advance', traceId = context.traceId,
                        code = type(advanceError) == 'table'
                            and advanceError.code or 'CREATION_COORDINATOR_UNAVAILABLE' })
                end
            end
        end
        return value, nil
    end

    local methods = {}
    local operationNames = {
        'create', 'get', 'list', 'update', 'archive', 'delete', 'registries_begin',
        'types_register',
        'creation_requests_get', 'creation_requests_approve', 'creation_requests_reject',
        'relation_types_register', 'duty_states_register',
        'relationships_get', 'relationships_list',
        'relationships_create', 'relationships_update',
        'members_get', 'members_list', 'members_invite', 'members_accept',
        'members_decline', 'members_revoke_invite',
        'members_transition', 'members_transition_policy_get',
        'members_transition_policy_set', 'members_set_grade',
        'members_set_visibility', 'members_set_primary',
        'reporting_set',
        'grades_create', 'grades_update', 'roles_create', 'roles_update',
        'roles_assign', 'roles_remove', 'capabilities_set', 'capabilities_check',
        'capabilities_explain', 'duty_start', 'duty_update', 'duty_stop', 'duty_list',
        'assignments_get', 'assignments_list',
        'assignments_create', 'assignments_join', 'assignments_leave',
        'assignments_complete', 'assignments_cancel',
        'delegations_create', 'delegations_revoke', 'applications_submit',
        'applications_review', 'applications_withdraw',
        'proposals_create', 'proposals_approve',
        'proposals_reject', 'policies_set', 'policies_simulate',
        'attributes_get', 'attributes_register_schema', 'attributes_set', 'definitions_sync',
        'directory_list', 'history_list', 'self_snapshot',
        'compatibility_snapshot', 'compatibility_resolve_target', 'compatibility_set_primary_grade', 'doctor'
    }
    for _, name in ipairs(operationNames) do
        local operation = name
        methods[name] = function(request, context)
            local ok, value, operationError = pcall(invoke, operation, request, context)
            if not ok then
                reportUnexpectedError(
                    errorSink, 'synex_groups', operation, context, request)
                return nil, Foundation.domainError('DATABASE_ERROR', 'The Groups operation could not be completed.', true)
            end
            return value, operationError
        end
    end
    return methods
end
return createService
end
