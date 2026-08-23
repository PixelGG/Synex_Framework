local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityCharacterDeletionReconciliation = function(deps)
    local platform = assert(deps.platform, 'character deletion reconciliation requires platform')
    local foundation = assert(deps.foundation, 'character deletion reconciliation requires foundation')
    local database = assert(deps.database, 'character deletion reconciliation requires database')
    local leases = assert(deps.leases, 'character deletion reconciliation requires leases')
    local instances = assert(deps.instances, 'character deletion reconciliation requires instances')
    local owners = assert(deps.owners, 'character deletion reconciliation requires owners')
    local messaging = assert(deps.messaging, 'character deletion reconciliation requires messaging')
    local stateService = assert(deps.stateService, 'character deletion reconciliation requires state')
    local invokeParticipant = assert(deps.invokeParticipant,
        'character deletion reconciliation requires participant invocation')
    local findParticipant = assert(deps.findParticipant,
        'character deletion reconciliation requires participant lookup')
    local instanceId = assert(deps.instanceId,
        'character deletion reconciliation requires an instance ID')
    local coreResource = assert(deps.coreResource,
        'character deletion reconciliation requires the core resource')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local participantMaximum = type(deps.participantMaximum) == 'number'
        and math.type(deps.participantMaximum) == 'integer'
        and math.max(1, math.min(deps.participantMaximum, 128)) or 128
    local leaseTtlSeconds = 120
    local leaseHeartbeatMs = 10000
    local maximumExactInteger = 9007199254740991
    local allowedActions = { allow = true, delete = true, anonymize = true, retain = true }
    local planFields = { schema = true, characterId = true, actions = true }
    local actionFields = {
        owner = true, participant = true, action = true, metadata = true, notify = true
    }

    local function affectedRows(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end

    local function validCharacterId(value)
        return type(value) == 'string' and #value >= 1 and #value <= 36
            and value:match('^[a-z0-9][a-z0-9_%-]*$') ~= nil
    end

    local function nextLeaseOwner()
        local owner = tostring(instanceId) .. ':character-delete:' .. foundation.nextId('delete')
        if #owner > 96 then error('character deletion lease owner exceeds the persisted bound') end
        return owner
    end

    local function hasOnlyFields(value, allowed)
        for key in pairs(value) do
            if type(key) ~= 'string' or allowed[key] ~= true then return false end
        end
        return true
    end

    local function validateMetadata(value, depth, state)
        state.nodes = state.nodes + 1
        if state.nodes > 512 or depth > 8 then return false end
        local valueType = type(value)
        if valueType == 'nil' or valueType == 'boolean' then return true end
        if valueType == 'string' then
            state.stringBytes = state.stringBytes + #value
            return #value <= 4096 and state.stringBytes <= 4096
        end
        if valueType == 'number' then
            return value == value and value ~= math.huge and value ~= -math.huge
        end
        if valueType ~= 'table' or getmetatable(value) ~= nil or state.seen[value] then
            return false
        end
        state.seen[value] = true
        local keyCount, numericKeys, stringKeys, maximumIndex = 0, 0, 0, 0
        for key in pairs(value) do
            keyCount = keyCount + 1
            if keyCount > 128 then state.seen[value] = nil return false end
            if type(key) == 'number' and math.type(key) == 'integer' and key >= 1 then
                numericKeys = numericKeys + 1
                maximumIndex = math.max(maximumIndex, key)
            elseif type(key) == 'string' and #key >= 1 and #key <= 128 then
                stringKeys = stringKeys + 1
            else
                state.seen[value] = nil
                return false
            end
        end
        if numericKeys > 0 and stringKeys > 0
            or numericKeys > 0 and maximumIndex ~= numericKeys then
            state.seen[value] = nil
            return false
        end
        for _, child in pairs(value) do
            if not validateMetadata(child, depth + 1, state) then
                state.seen[value] = nil
                return false
            end
        end
        state.seen[value] = nil
        return true
    end

    local function validatePlan(plan)
        if type(plan) ~= 'table' or getmetatable(plan) ~= nil or plan.schema ~= 1
            or not validCharacterId(plan.characterId) or type(plan.actions) ~= 'table'
            or getmetatable(plan.actions) ~= nil or #plan.actions > participantMaximum
            or not hasOnlyFields(plan, planFields) then
            return nil, foundation.error('INVALID_DELETE_PLAN',
                'The persisted character deletion plan is invalid.')
        end
        local actionCount = 0
        for key in pairs(plan.actions) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or key > #plan.actions then
                return nil, foundation.error('INVALID_DELETE_PLAN',
                    'The persisted character deletion action list is not dense.')
            end
            actionCount = actionCount + 1
        end
        if actionCount ~= #plan.actions then
            return nil, foundation.error('INVALID_DELETE_PLAN',
                'The persisted character deletion action list is not dense.')
        end
        for index, action in ipairs(plan.actions) do
            if type(action) ~= 'table' or getmetatable(action) ~= nil
                or not hasOnlyFields(action, actionFields)
                or type(action.owner) ~= 'string' or #action.owner < 7 or #action.owner > 64
                or not action.owner:match('^synex_[a-z0-9_]+$')
                or (action.participant ~= nil and (type(action.participant) ~= 'string'
                    or #action.participant < 1 or #action.participant > 64
                    or not action.participant:match('^[a-z][a-z0-9_.%-]*$')))
                or not allowedActions[action.action] or (action.notify ~= nil
                    and type(action.notify) ~= 'boolean') then
                return nil, foundation.error('INVALID_DELETE_PLAN',
                    ('Character deletion action %d is invalid.'):format(index))
            end
            if action.metadata ~= nil then
                local metadataValid = validateMetadata(action.metadata, 1, {
                    nodes = 0, stringBytes = 0, seen = {}
                })
                local encodedOk, encoded = false, nil
                if metadataValid then
                    encodedOk, encoded = pcall(platform.jsonEncode, action.metadata)
                end
                if not metadataValid or not encodedOk or type(encoded) ~= 'string'
                    or #encoded > 4096 then
                    return nil, foundation.error('INVALID_DELETE_PLAN',
                        ('Character deletion action %d metadata is invalid.'):format(index))
                end
            end
        end
        return true, nil
    end

    local function validPlanIdentity(planId, expectedVersion)
        return type(planId) == 'string' and #planId >= 1 and #planId <= 36
            and planId:match('^[a-z0-9_]+$') ~= nil
            and type(expectedVersion) == 'number' and math.type(expectedVersion) == 'integer'
            and expectedVersion >= 1 and expectedVersion <= maximumExactInteger
    end

    local function addressablePlanIdentity(planId, expectedVersion)
        if type(planId) ~= 'string' or #planId < 1 or #planId > 36 then return false end
        if type(expectedVersion) == 'number' then
            return math.type(expectedVersion) == 'integer' and expectedVersion >= 1
        end
        return type(expectedVersion) == 'string' and #expectedVersion <= 20
            and expectedVersion:match('^[0-9]+$') ~= nil
            and expectedVersion:match('^0+$') == nil
    end

    local function retireLease(query, planId, lease)
        local updated
        if lease ~= nil then
            updated = query([[UPDATE `synex_cluster_leases`
                SET `owner_id` = 'terminal',
                    `fencing_token` = CASE
                        WHEN `fencing_token` < 18446744073709551615
                            THEN `fencing_token` + 1
                        ELSE `fencing_token`
                    END,
                    `expires_at` = CURRENT_TIMESTAMP(6),
                    `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
                WHERE `lease_name` = ? AND `owner_id` = ? AND `fencing_token` = ?
                    AND `expires_at` > CURRENT_TIMESTAMP(6)
                    AND `terminal_compaction_at` IS NULL]], {
                'character-delete:' .. planId, lease.owner, lease.fencingToken
            })
            if affectedRows(updated) ~= 1 then
                return nil, foundation.error('DELETE_LEASE_LOST',
                    'The character deletion lease changed before terminal commit.', {
                        retryable = true
                    })
            end
            return true, nil
        end
        updated = query([[UPDATE `synex_cluster_leases`
            SET `owner_id` = 'terminal',
                `fencing_token` = CASE
                    WHEN `fencing_token` < 18446744073709551615
                        THEN `fencing_token` + 1
                    ELSE `fencing_token`
                END,
                `expires_at` = CURRENT_TIMESTAMP(6),
                `terminal_compaction_at` = CURRENT_TIMESTAMP(6)
            WHERE `lease_name` = ? AND `terminal_compaction_at` IS NULL]], {
            'character-delete:' .. planId
        })
        local count = affectedRows(updated)
        if count == nil or count < 0 or count > 1 then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Character deletion lease retirement returned an invalid affected-row count.')
        end
        return true, nil
    end

    local function markFailed(planId, expectedVersion, code)
        local normalized = type(code) == 'string'
            and code:upper():gsub('[^A-Z0-9_]', '_'):sub(1, 96)
            or 'INVALID_DELETE_PLAN'
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            local affected = query([[UPDATE `synex_character_deletion_plans`
                SET `state` = 'failed', `failure_code` = ?,
                    `executed_at` = CURRENT_TIMESTAMP(6), `lease_fencing_token` = NULL,
                    `version` = LEAST(`version` + 1, 18446744073709551615)
                WHERE `id` = ? AND `version` = ?
                    AND `state` IN ('pending', 'executing')]],
                { normalized, planId, expectedVersion })
            if affectedRows(affected) ~= 1 then
                domainError = foundation.error('DELETE_PLAN_CONFLICT',
                    'The character deletion plan changed during invalid-plan handling.', {
                        retryable = true
                    })
                return false
            end
            local retired
            retired, domainError = retireLease(query, planId, nil)
            return retired == true
        end)
        if not committed then return nil, domainError or transactionError end
        return true, nil
    end

    local function beginAttempt(planId, expectedVersion, fencingToken)
        local affected, updateError = database:update([[UPDATE `synex_character_deletion_plans`
            SET `state` = 'executing', `lease_fencing_token` = ?,
                `last_attempt_at` = CURRENT_TIMESTAMP(6),
                `next_attempt_at` = DATE_ADD(CURRENT_TIMESTAMP(6), INTERVAL 5 SECOND),
                `attempt_count` = LEAST(`attempt_count` + 1, 4294967295),
                `version` = LEAST(`version` + 1, 18446744073709551615)
            WHERE `id` = ? AND `version` = ?
                AND `state` IN ('pending', 'executing')
                AND `next_attempt_at` <= CURRENT_TIMESTAMP(6)]],
            { fencingToken, planId, expectedVersion })
        if updateError then return nil, updateError end
        if tonumber(affected) ~= 1 then
            return nil, foundation.error('DELETE_PLAN_CONFLICT',
                'The character deletion plan is no longer eligible for reconciliation.', {
                    retryable = true
                })
        end
        return expectedVersion + 1, nil
    end

    local function complete(planId, expectedVersion, lease)
        local domainError = nil
        local committed, transactionError = database:withTransaction(function(query)
            local affected = query([[UPDATE `synex_character_deletion_plans`
                SET `state` = 'completed', `failure_code` = NULL,
                    `executed_at` = CURRENT_TIMESTAMP(6), `lease_fencing_token` = NULL,
                    `version` = LEAST(`version` + 1, 18446744073709551615)
                WHERE `id` = ? AND `version` = ? AND `lease_fencing_token` = ?
                    AND `state` = 'executing']], {
                planId, expectedVersion, lease.fencingToken
            })
            if affectedRows(affected) ~= 1 then
                domainError = foundation.error('DELETE_PLAN_CONFLICT',
                    'The character deletion plan changed during reconciliation.', {
                        retryable = true
                    })
                return false
            end
            local retired
            retired, domainError = retireLease(query, planId, lease)
            return retired == true
        end)
        if not committed then return nil, domainError or transactionError end
        return true, nil
    end

    local function startHeartbeat(lease)
        local heartbeat = { active = true, failure = nil }
        if type(platform.createThread) ~= 'function' or type(platform.wait) ~= 'function' then
            return heartbeat, nil
        end
        local launched, launchFailure = foundation.safeCall(platform.createThread, function()
            while heartbeat.active do
                platform.wait(leaseHeartbeatMs)
                if heartbeat.active then
                    local renewed, renewError = leases:renew(lease)
                    if not renewed then
                        heartbeat.failure = renewError or foundation.error(
                            'DELETE_LEASE_LOST', 'The character deletion lease expired.', {
                                retryable = true
                            })
                        heartbeat.active = false
                    end
                end
            end
        end)
        if not launched then
            return nil, foundation.error('DELETE_LEASE_HEARTBEAT_FAILED',
                'The character deletion lease heartbeat could not be started.', {
                    retryable = true,
                    details = {
                        cause = foundation.failureCode(
                            launchFailure, 'DELETE_LEASE_HEARTBEAT_FAILED')
                    }
                })
        end
        return heartbeat, nil
    end

    local function process(planId, expectedVersion, plan, expectedCharacterId)
        if not validPlanIdentity(planId, expectedVersion) then
            return nil, foundation.error('INVALID_DELETE_PLAN',
                'The persisted character deletion plan identity is invalid.')
        end
        local valid, validationError = validatePlan(plan)
        if valid and (not validCharacterId(expectedCharacterId)
            or plan.characterId ~= expectedCharacterId) then
            valid = nil
            validationError = foundation.error('INVALID_DELETE_PLAN',
                'The persisted deletion plan does not match its character record.')
        end
        if not valid then
            local marked, markerError = markFailed(
                planId, expectedVersion, validationError.code)
            return nil, markerError or (not marked and validationError) or validationError
        end
        local activeBootId, bootError = instances:bootId()
        if not activeBootId then return nil, bootError end
        local lease, leaseError = leases:acquire('character-delete:' .. planId,
            nextLeaseOwner(), leaseTtlSeconds, instanceId, activeBootId)
        if not lease then
            -- A lease loser must not mutate the plan. The current lease holder may
            -- already have read expectedVersion and is the only worker allowed to
            -- advance it; changing next_attempt_at or version here would livelock
            -- two synchronized reconcilers.
            return nil, leaseError or foundation.error(
                'DELETE_LEASE_UNAVAILABLE',
                'The character deletion lease is unavailable.', { retryable = true })
        end
        local fencingToken = tonumber(lease.fencingToken)
        if not fencingToken or math.type(fencingToken) ~= 'integer' or fencingToken < 1
            or fencingToken > maximumExactInteger then
            leases:release(lease)
            return nil, foundation.error('DELETE_LEASE_INVALID',
                'The character deletion lease has no valid fencing token.')
        end
        local heartbeat, heartbeatError = startHeartbeat(lease)
        local function release()
            if heartbeat then heartbeat.active = false end
            local released, releaseError = leases:release(lease)
            if not released then
                logger:error('character deletion reconciliation lease release failed', {
                    planId = planId,
                    code = foundation.failureCode(releaseError, 'DELETE_LEASE_RELEASE_FAILED')
                })
            end
        end
        if not heartbeat then
            release()
            return nil, heartbeatError
        end
        local function fence()
            if heartbeat.failure then
                return nil, foundation.error('DELETE_LEASE_LOST',
                    'The character deletion lease was lost.', {
                        retryable = true,
                        details = {
                            cause = foundation.failureCode(
                                heartbeat.failure, 'DELETE_LEASE_LOST')
                        }
                    })
            end
            local renewed, renewError = leases:renew(lease)
            if not renewed then
                heartbeat.failure = renewError
                return nil, foundation.error('DELETE_LEASE_LOST',
                    'The character deletion lease could not be renewed.', {
                        retryable = true,
                        details = {
                            cause = foundation.failureCode(renewError, 'DELETE_LEASE_LOST')
                        }
                    })
            end
            return true, nil
        end
        local fenced, fenceError = fence()
        if not fenced then
            release()
            return nil, fenceError
        end
        local attemptVersion, attemptError = beginAttempt(
            planId, expectedVersion, fencingToken)
        if not attemptVersion then release() return nil, attemptError end
        for _, action in ipairs(plan.actions) do
            if action.notify ~= false then
                fenced, fenceError = fence()
                if not fenced then release() return nil, fenceError end
                local participant = findParticipant(action)
                if not participant or not foundation.isCallable(participant.deleteCommit) then
                    release()
                    return nil, foundation.error('DELETE_PARTICIPANT_UNAVAILABLE',
                        'A character deletion participant is unavailable.', {
                            retryable = true
                        })
                end
                local participantPlan = {
                    schema = plan.schema,
                    characterId = plan.characterId,
                    actions = { foundation.copy(action) }
                }
                local _, participantError = invokeParticipant(
                    participant, participant.deleteCommit, foundation.readonly({
                        planId = planId,
                        plan = participantPlan
                    }))
                if participantError then release() return nil, participantError end
                fenced, fenceError = fence()
                if not fenced then release() return nil, fenceError end
            end
        end
        fenced, fenceError = fence()
        if not fenced then release() return nil, fenceError end
        local purgedState, purgeError = stateService:purgeSubject(
            'character', plan.characterId)
        if not purgedState then release() return nil, purgeError end
        fenced, fenceError = fence()
        if not fenced then release() return nil, fenceError end
        local completed, completionError = complete(planId, attemptVersion, lease)
        release()
        if not completed then return nil, completionError end
        local _, eventError = messaging.events:publish(
            coreResource, owners:epoch(coreResource), 'synex.characters.deleted', {
                characterId = plan.characterId,
                planId = planId
            })
        if eventError then
            logger:error('character deletion event publication failed', {
                planId = planId,
                code = foundation.failureCode(eventError, 'EVENT_PUBLICATION_FAILED')
            })
        end
        return {
            planId = planId,
            characterId = plan.characterId,
            state = 'completed'
        }, nil
    end

    local service = {}
    function service:validate(plan)
        return validatePlan(plan)
    end
    function service:process(planId, expectedVersion, plan, expectedCharacterId)
        return process(planId, expectedVersion, plan, expectedCharacterId)
    end
    function service:reconcile(limit)
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Deletion reconciliation limit must be 1 through 32.')
        end
        local rows, queryError = database:query([[SELECT `id`, `character_id`, `version`,
                CASE WHEN OCTET_LENGTH(`plan_json`) <= 65536 THEN `plan_json` ELSE NULL END
                    AS `plan_json`
            FROM `synex_character_deletion_plans`
            WHERE `state` IN ('pending', 'executing')
                AND `next_attempt_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `next_attempt_at`, `created_at`, `id` LIMIT ?]], { limit })
        if not rows then return nil, queryError end
        local report = { examined = #rows, completed = 0, deferred = 0, invalid = 0 }
        for _, row in ipairs(rows) do
            local version = tonumber(row.version)
            local identityValid = validPlanIdentity(row.id, version)
            local addressable = addressablePlanIdentity(row.id, row.version)
            local encodedValid = type(row.plan_json) == 'string'
                and #row.plan_json <= 65536
            local decodedOk, plan = false, nil
            if encodedValid then decodedOk, plan = pcall(platform.jsonDecode, row.plan_json) end
            if not identityValid or not encodedValid or not decodedOk
                or type(plan) ~= 'table' then
                local marked = addressable and markFailed(
                    row.id, row.version, 'INVALID_DELETE_PLAN') or nil
                if not marked and addressable then report.deferred = report.deferred + 1
                else report.invalid = report.invalid + 1 end
            else
                local completed, reconciliationError = process(
                    row.id, version, plan, row.character_id)
                if completed then
                    report.completed = report.completed + 1
                    metrics:increment(
                        'synex_character_delete_reconciliation_total', { result = 'completed' })
                elseif reconciliationError
                    and reconciliationError.code == 'INVALID_DELETE_PLAN' then
                    report.invalid = report.invalid + 1
                    metrics:increment(
                        'synex_character_delete_reconciliation_total', { result = 'invalid_plan' })
                else
                    report.deferred = report.deferred + 1
                    metrics:increment('synex_character_delete_reconciliation_total', {
                        result = reconciliationError
                            and reconciliationError.code == 'DELETE_PARTICIPANT_UNAVAILABLE'
                            and 'participant_unavailable' or 'error'
                    })
                end
            end
        end
        return report, nil
    end
    return service
end
