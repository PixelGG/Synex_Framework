return function(port, context)
    local Foundation = assert(type(context.Foundation) == 'table' and context.Foundation,
        'groups deletions require Foundation')
    local domainError = assert(type(context.domainError) == 'function' and context.domainError,
        'groups deletions require domainError')
    local rows = assert(type(context.many) == 'function' and context.many,
        'groups deletions require many')
    local withTransaction = assert(type(context.withTransaction) == 'function'
        and context.withTransaction, 'groups deletions require withTransaction')
    local effect = assert(type(context.effect) == 'function' and context.effect,
        'groups deletions require effect')
    local writeEffect = assert(type(context.writeEffect) == 'function' and context.writeEffect,
        'groups deletions require writeEffect')
    local nextId = assert(type(context.id) == 'function' and context.id,
        'groups deletions require id')
    local cache = assert(type(context.cache) == 'table' and context.cache,
        'groups deletions require cache')
    local planStates = {
        pending = true, executing = true, completed = true, blocked = true, failed = true
    }

    local function view(row)
        local requestVersion = tonumber(row.request_version or row.version)
        local groupVersion = tonumber(row.group_version)
        local requestedGroupVersion = tonumber(row.requested_group_version)
        if not Foundation.isPublicId(row.deletion_request_id or row.public_id)
            or not Foundation.isPublicId(row.group_public_id)
            or type(row.state) ~= 'string'
            or not requestVersion or math.type(requestVersion) ~= 'integer'
            or requestVersion < 1
            or not groupVersion or math.type(groupVersion) ~= 'integer'
            or groupVersion < 1
            or not requestedGroupVersion or math.type(requestedGroupVersion) ~= 'integer'
            or requestedGroupVersion < 1 or groupVersion < requestedGroupVersion then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The persisted organization deletion request is invalid.', true)
        end
        return {
            deletion_request_id = row.deletion_request_id or row.public_id,
            group_id = row.group_public_id,
            plan_id = row.plan_id,
            state = row.state,
            plan_state = row.plan_state,
            failure_code = row.failure_code,
            group_status = type(row.lifecycle_state) == 'string'
                and row.lifecycle_state:lower() or row.group_status,
            group_version = groupVersion,
            version = requestVersion,
            replayed = false
        }, nil
    end

    local function loadDeletionRequest(requestId)
        local found = rows([[SELECT `request`.`public_id` AS `deletion_request_id`,
                `request`.`plan_id`, `request`.`state`, `request`.`plan_state`,
                `request`.`failure_code`, `request`.`requested_group_version`,
                `request`.`group_version`, `request`.`version` AS `request_version`,
                `request`.`reason_code`, `request`.`reason_text`, `request`.`actor_ref`,
                `group_record`.`id` AS `group_internal_id`,
                `group_record`.`public_id` AS `group_public_id`,
                `group_record`.`status` AS `group_status`,
                `group_record`.`version` AS `stored_group_version`,
                `profile`.`lifecycle_state`, `profile`.`version` AS `profile_version`,
                `profile`.`archived_at`, `profile`.`deleted_at`
            FROM `synex_group_deletion_requests` AS `request`
            INNER JOIN `synex_groups` AS `group_record`
                ON `group_record`.`id` = `request`.`group_id`
            INNER JOIN `synex_group_organization_profiles` AS `profile`
                ON `profile`.`group_id` = `group_record`.`id`
            WHERE `request`.`public_id` = ? LIMIT 2]], { requestId })
        if type(found) ~= 'table' or #found > 1 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The organization deletion request identity is invalid.', true)
        end
        if not found[1] then
            return nil, domainError('GROUP_DELETION_NOT_FOUND',
                'The organization deletion request does not exist.')
        end
        return found[1], nil
    end

    local function validatePlan(requestId, row, plan)
        if type(plan) ~= 'table' or not Foundation.isPublicId(plan.planId)
            or plan.domain ~= 'group' or plan.subjectId ~= row.group_public_id
            or plan.requesterOwner ~= 'synex_groups' or not planStates[plan.state]
            or type(plan.context) ~= 'table'
            or plan.context.deletionRequestId ~= requestId
            or plan.reason ~= row.reason_text or type(plan.actions) ~= 'table'
            or #plan.actions < 1 or #plan.actions > 64 then
            return nil, domainError('DELETION_PLAN_INVALID',
                'The Core deletion plan does not match the organization request.', true)
        end
        local blocked = false
        for index, action in ipairs(plan.actions) do
            if type(action) ~= 'table' or tonumber(action.index) ~= index
                or type(action.providerOwner) ~= 'string'
                or type(action.providerName) ~= 'string'
                or (action.state ~= 'pending' and action.state ~= 'completed') then
                return nil, domainError('DELETION_PLAN_INVALID',
                    'The Core deletion plan contains an invalid provider action.', true)
            end
            blocked = blocked or action.decision == 'block'
            if plan.state == 'completed' and action.state ~= 'completed' then
                return nil, domainError('DELETION_PLAN_INVALID',
                    'A completed Core deletion plan contains pending work.', true)
            end
        end
        if plan.state == 'blocked' and not blocked then
            return nil, domainError('DELETION_PLAN_INVALID',
                'A blocked Core deletion plan has no blocking provider.', true)
        end
        return true, nil
    end

    function port:getGroupDeletion(requestId)
        if not Foundation.isPublicId(requestId) then
            return nil, domainError('VALIDATION_FAILED',
                'The organization deletion request identity is invalid.')
        end
        local row, loadError = loadDeletionRequest(requestId)
        if not row then return nil, loadError end
        return view(row)
    end

    function port:getGroupDeletionPlanRequest(requestId)
        if not Foundation.isPublicId(requestId) then
            return nil, domainError('VALIDATION_FAILED',
                'The organization deletion request identity is invalid.')
        end
        local row, loadError = loadDeletionRequest(requestId)
        if not row then return nil, loadError end
        if type(row.reason_text) ~= 'string' or #row.reason_text < 1
            or #row.reason_text > 256 then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The organization deletion reason is invalid.', true)
        end
        return {
            deletionRequestId = requestId,
            groupId = row.group_public_id,
            planId = row.plan_id,
            state = row.state,
            reason = row.reason_text
        }, nil
    end

    function port:listGroupDeletions(maximum)
        maximum = tonumber(maximum)
        if not maximum or math.type(maximum) ~= 'integer'
            or maximum < 1 or maximum > 32 then
            return nil, domainError('VALIDATION_FAILED',
                'The organization deletion reconciliation limit is invalid.')
        end
        local pending = rows([[SELECT `public_id`
            FROM `synex_group_deletion_requests`
            WHERE `state` IN ('planning', 'dissolving')
            ORDER BY `updated_at`, `id` LIMIT ?]], { maximum })
        if type(pending) ~= 'table' or #pending > maximum then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The organization deletion reconciliation batch is invalid.', true)
        end
        local result = {}
        for index, row in ipairs(pending) do
            if not Foundation.isPublicId(row.public_id) then
                return nil, domainError('DATABASE_RESULT_INVALID',
                    'The organization deletion reconciliation identity is invalid.', true)
            end
            result[index] = row.public_id
        end
        return result, nil
    end

    function port:preflightGroupDeletion(subjectId, requestId)
        if not Foundation.isPublicId(subjectId) or not Foundation.isPublicId(requestId) then
            return nil, domainError('INVALID_DELETION_REQUEST',
                'The organization deletion preflight identity is invalid.')
        end
        local row, loadError = loadDeletionRequest(requestId)
        if not row then return nil, loadError end
        if row.group_public_id ~= subjectId then
            return {
                decision = 'block',
                reason = 'The deletion request belongs to another organization.',
                metadata = { code = 'GROUP_DELETION_SUBJECT_MISMATCH' }
            }, nil
        end
        local storedGroupVersion = tonumber(row.stored_group_version)
        local profileVersion = tonumber(row.profile_version)
        if row.state ~= 'planning' or row.plan_id ~= nil
            or row.group_status ~= 'archived' or row.lifecycle_state ~= 'ARCHIVED'
            or row.archived_at == nil or row.deleted_at ~= nil
            or storedGroupVersion ~= tonumber(row.group_version)
            or profileVersion ~= storedGroupVersion then
            return {
                decision = 'block',
                reason = 'The organization is not in a stable archived deletion state.',
                metadata = { code = 'GROUP_DELETION_STATE_INVALID' }
            }, nil
        end
        return {
            decision = 'retain',
            reason = 'Synex Groups retains its soft-deleted domain history.',
            metadata = { deletionRequestId = requestId }
        }, nil
    end

    function port:applyGroupDeletionPlan(requestId, plan)
        if not Foundation.isPublicId(requestId) then
            return nil, domainError('VALIDATION_FAILED',
                'The organization deletion request identity is invalid.')
        end
        local initial, loadError = loadDeletionRequest(requestId)
        if not initial then return nil, loadError end
        local valid, planError = validatePlan(requestId, initial, plan)
        if not valid then return nil, planError end
        local traceId, traceError = nextId('groups_deletion_reconcile')
        if not traceId then return nil, traceError end
        local operationError
        local committed, transactionError = withTransaction(function(tx)
            local row = tx.one([[SELECT `request`.`id` AS `request_internal_id`,
                    `request`.`public_id` AS `deletion_request_id`, `request`.`plan_id`,
                    `request`.`state`, `request`.`plan_state`, `request`.`failure_code`,
                    `request`.`requested_group_version`, `request`.`group_version`,
                    `request`.`version` AS `request_version`, `request`.`reason_code`,
                    `request`.`reason_text`, `request`.`actor_ref`,
                    `group_record`.`id` AS `group_internal_id`,
                    `group_record`.`public_id` AS `group_public_id`,
                    `group_record`.`status` AS `group_status`,
                    `group_record`.`version` AS `stored_group_version`,
                    `profile`.`lifecycle_state`, `profile`.`version` AS `profile_version`,
                    `profile`.`archived_at`, `profile`.`deleted_at`
                FROM `synex_group_deletion_requests` AS `request`
                INNER JOIN `synex_groups` AS `group_record`
                    ON `group_record`.`id` = `request`.`group_id`
                INNER JOIN `synex_group_organization_profiles` AS `profile`
                    ON `profile`.`group_id` = `group_record`.`id`
                WHERE `request`.`public_id` = ? FOR UPDATE]], { requestId })
            if not row then
                operationError = domainError('GROUP_DELETION_NOT_FOUND',
                    'The organization deletion request does not exist.')
                return nil, operationError
            end
            local revalidated, revalidationError = validatePlan(requestId, row, plan)
            if not revalidated then
                operationError = revalidationError
                return nil, operationError
            end
            if row.plan_id ~= nil and row.plan_id ~= plan.planId then
                operationError = domainError('DELETION_PLAN_CONFLICT',
                    'The organization deletion request is bound to another Core plan.')
                return nil, operationError
            end
            if row.state == 'deleted' or row.state == 'blocked' or row.state == 'failed' then
                if row.plan_id == plan.planId and row.plan_state == plan.state then
                    return true, nil
                end
                operationError = domainError('DELETION_PLAN_CONFLICT',
                    'The terminal organization deletion request cannot change plans.')
                return nil, operationError
            end
            local groupVersion = tonumber(row.stored_group_version)
            local profileVersion = tonumber(row.profile_version)
            local requestVersion = tonumber(row.request_version)
            if not groupVersion or not profileVersion or groupVersion ~= profileVersion
                or groupVersion ~= tonumber(row.group_version) or not requestVersion then
                operationError = domainError('DATABASE_RESULT_INVALID',
                    'The organization deletion lifecycle versions are inconsistent.', true)
                return nil, operationError
            end

            if plan.state == 'blocked' then
                if row.state ~= 'planning' or row.lifecycle_state ~= 'ARCHIVED'
                    or row.group_status ~= 'archived' then
                    operationError = domainError('DELETION_PLAN_CONFLICT',
                        'A blocked plan cannot replace an active dissolution.')
                    return nil, operationError
                end
                local changed = tx.affected([[UPDATE `synex_group_deletion_requests`
                    SET `plan_id` = ?, `state` = 'blocked', `plan_state` = 'blocked',
                        `blocked_at` = CURRENT_TIMESTAMP(6),
                        `completed_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `state` = 'planning'
                        AND `plan_id` IS NULL]], {
                    plan.planId, row.request_internal_id, requestVersion
                })
                if changed ~= 1 then
                    operationError = domainError('CONCURRENT_MODIFICATION',
                        'The organization deletion request changed during blocking.', true)
                    return nil, operationError
                end
                local item = effect('group.deletion_blocked', 'deletion_request',
                    requestId, row.group_public_id, row.actor_ref,
                    { state = 'planning', version = requestVersion },
                    { state = 'blocked', plan_id = plan.planId,
                        group_status = 'archived', version = requestVersion + 1 },
                    row.reason_code, requestVersion + 1)
                local written, writeError = writeEffect(tx, item,
                    { actor_character_id = row.actor_ref },
                    { caller = 'synex_groups', traceId = traceId })
                if not written then operationError = writeError return nil, writeError end
                return true, nil
            end

            if plan.state == 'failed' then
                local failureCode = type(plan.failureCode) == 'string'
                    and plan.failureCode:upper():gsub('[^A-Z0-9_]', '_'):sub(1, 96)
                    or 'DELETION_PLAN_FAILED'
                if #failureCode < 2 or not failureCode:match('^[A-Z][A-Z0-9_]+$') then
                    failureCode = 'DELETION_PLAN_FAILED'
                end
                local changed = tx.affected([[UPDATE `synex_group_deletion_requests`
                    SET `plan_id` = ?, `state` = 'failed', `plan_state` = 'failed',
                        `failure_code` = ?, `completed_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ?
                        AND `state` IN ('planning', 'dissolving')
                        AND (`plan_id` IS NULL OR `plan_id` = ?)]], {
                    plan.planId, failureCode, row.request_internal_id,
                    requestVersion, plan.planId
                })
                if changed ~= 1 then
                    operationError = domainError('CONCURRENT_MODIFICATION',
                        'The organization deletion request changed during failure handling.', true)
                    return nil, operationError
                end
                return true, nil
            end

            if row.state == 'planning' then
                if row.lifecycle_state ~= 'ARCHIVED' or row.group_status ~= 'archived'
                    or row.archived_at == nil or row.deleted_at ~= nil then
                    operationError = domainError('DELETION_PLAN_CONFLICT',
                        'The organization is no longer safely archived.')
                    return nil, operationError
                end
                local groupChanged = tx.affected([[UPDATE `synex_groups`
                    SET `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `status` = 'archived']],
                    { row.group_internal_id, groupVersion })
                local profileChanged = tx.affected([[UPDATE `synex_group_organization_profiles`
                    SET `lifecycle_state` = 'DISSOLVING',
                        `lifecycle_reason_code` = ?,
                        `state_changed_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `group_id` = ? AND `version` = ?
                        AND `lifecycle_state` = 'ARCHIVED'
                        AND `archived_at` IS NOT NULL AND `deleted_at` IS NULL]], {
                    row.reason_code, row.group_internal_id, profileVersion
                })
                local requestChanged = tx.affected([[UPDATE `synex_group_deletion_requests`
                    SET `plan_id` = ?, `state` = 'dissolving', `plan_state` = ?,
                        `group_version` = ?, `dissolving_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `state` = 'planning'
                        AND `plan_id` IS NULL]], {
                    plan.planId, plan.state == 'completed' and 'pending' or plan.state,
                    groupVersion + 1, row.request_internal_id, requestVersion
                })
                if groupChanged ~= 1 or profileChanged ~= 1 or requestChanged ~= 1 then
                    operationError = domainError('CONCURRENT_MODIFICATION',
                        'The organization changed while dissolution was activated.', true)
                    return nil, operationError
                end
                local bumped = tx.affected([[UPDATE `synex_group_read_model_versions`
                    SET `model_version` = `model_version` + 1,
                        `invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group_id` = ?]], { row.group_internal_id })
                if bumped ~= 1 then
                    operationError = domainError('DATABASE_RESULT_INVALID',
                        'The organization read model could not be invalidated.', true)
                    return nil, operationError
                end
                local item = effect('group.dissolving', 'group', row.group_public_id,
                    row.group_public_id, row.actor_ref,
                    { status = 'archived', version = groupVersion },
                    { status = 'dissolving', deletion_request_id = requestId,
                        plan_id = plan.planId, version = groupVersion + 1 },
                    row.reason_code, groupVersion + 1)
                local written, writeError = writeEffect(tx, item,
                    { actor_character_id = row.actor_ref },
                    { caller = 'synex_groups', traceId = traceId })
                if not written then operationError = writeError return nil, writeError end
                row.state = 'dissolving'
                row.plan_id = plan.planId
                row.plan_state = plan.state == 'completed' and 'pending' or plan.state
                row.request_version = requestVersion + 1
                row.group_version = groupVersion + 1
                row.stored_group_version = groupVersion + 1
                row.profile_version = profileVersion + 1
                row.lifecycle_state = 'DISSOLVING'
                requestVersion = requestVersion + 1
                groupVersion = groupVersion + 1
                profileVersion = profileVersion + 1
            elseif row.plan_id ~= plan.planId then
                operationError = domainError('DELETION_PLAN_CONFLICT',
                    'The dissolving organization is bound to another Core plan.')
                return nil, operationError
            end

            if plan.state == 'completed' then
                if row.state ~= 'dissolving' or row.lifecycle_state ~= 'DISSOLVING'
                    or row.group_status ~= 'archived' or row.archived_at == nil
                    or row.deleted_at ~= nil then
                    operationError = domainError('DELETION_PLAN_CONFLICT',
                        'The organization cannot be finalized from its current lifecycle state.')
                    return nil, operationError
                end
                local groupChanged = tx.affected([[UPDATE `synex_groups`
                    SET `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `status` = 'archived']],
                    { row.group_internal_id, groupVersion })
                local profileChanged = tx.affected([[UPDATE `synex_group_organization_profiles`
                    SET `lifecycle_state` = 'DELETED',
                        `lifecycle_reason_code` = ?,
                        `state_changed_at` = CURRENT_TIMESTAMP(6),
                        `deleted_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `group_id` = ? AND `version` = ?
                        AND `lifecycle_state` = 'DISSOLVING'
                        AND `archived_at` IS NOT NULL AND `deleted_at` IS NULL]], {
                    row.reason_code, row.group_internal_id, profileVersion
                })
                local requestChanged = tx.affected([[UPDATE `synex_group_deletion_requests`
                    SET `state` = 'deleted', `plan_state` = 'completed',
                        `group_version` = ?, `completed_at` = CURRENT_TIMESTAMP(6),
                        `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `state` = 'dissolving'
                        AND `plan_id` = ?]], {
                    groupVersion + 1, row.request_internal_id,
                    requestVersion, plan.planId
                })
                if groupChanged ~= 1 or profileChanged ~= 1 or requestChanged ~= 1 then
                    operationError = domainError('CONCURRENT_MODIFICATION',
                        'The organization changed during deletion finalization.', true)
                    return nil, operationError
                end
                local bumped = tx.affected([[UPDATE `synex_group_read_model_versions`
                    SET `model_version` = `model_version` + 1,
                        `invalidated_at` = CURRENT_TIMESTAMP(6)
                    WHERE `group_id` = ?]], { row.group_internal_id })
                if bumped ~= 1 then
                    operationError = domainError('DATABASE_RESULT_INVALID',
                        'The organization read model could not be invalidated.', true)
                    return nil, operationError
                end
                local item = effect('group.deleted', 'group', row.group_public_id,
                    row.group_public_id, row.actor_ref,
                    { status = 'dissolving', version = groupVersion },
                    { status = 'deleted', deletion_request_id = requestId,
                        plan_id = plan.planId, version = groupVersion + 1 },
                    row.reason_code, groupVersion + 1)
                local written, writeError = writeEffect(tx, item,
                    { actor_character_id = row.actor_ref },
                    { caller = 'synex_groups', traceId = traceId })
                if not written then operationError = writeError return nil, writeError end
            elseif row.plan_state ~= plan.state then
                local changed = tx.affected([[UPDATE `synex_group_deletion_requests`
                    SET `plan_state` = ?, `version` = `version` + 1
                    WHERE `id` = ? AND `version` = ? AND `state` = 'dissolving'
                        AND `plan_id` = ?]], {
                    plan.state, row.request_internal_id, requestVersion, plan.planId
                })
                if changed ~= 1 then
                    operationError = domainError('CONCURRENT_MODIFICATION',
                        'The organization deletion plan state changed concurrently.', true)
                    return nil, operationError
                end
            end
            return true, nil
        end)
        if not committed then return nil, operationError or transactionError end
        cache:invalidatePrefix('group:' .. initial.group_public_id)
        cache:invalidatePrefix('directory:' .. initial.group_public_id)
        cache:invalidatePrefix('membership:')
        local updated, updatedError = loadDeletionRequest(requestId)
        if not updated then return nil, updatedError end
        return view(updated)
    end
end
