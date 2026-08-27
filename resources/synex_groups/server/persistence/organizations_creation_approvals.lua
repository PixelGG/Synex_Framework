return function(Foundation)
local Shared = require('server.persistence.organizations_shared')(Foundation)
local OrganizationsLifecycle = require('server.persistence.organizations_creation')(Foundation)
local affectedRows = Shared.affectedRows
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local rejected = Shared.rejected
local releaseSlugReservation = Shared.releaseSlugReservation
local read = {}
local execute = {}

local function validVersion(value)
    value = tonumber(value)
    return value and math.type(value) == 'integer' and value >= 1 and value or nil
end

local function decodeRequest(runtime, encoded)
    if type(encoded) ~= 'string' or #encoded < 2 or #encoded > 32768 then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored organization creation request is invalid.', true)
    end
    local decodedOk, decoded = pcall(runtime.jsonDecode, encoded)
    if not decodedOk or type(decoded) ~= 'table' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored organization creation request cannot be decoded.', true)
    end
    local copiedOk, copied = pcall(Foundation.copyPlain, decoded, {
        maximumDepth = 8,
        maximumKeys = 64,
        maximumStringBytes = 4096,
        preserveContainerKind = false
    })
    if not copiedOk or type(copied) ~= 'table' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored organization creation request exceeds supported bounds.', true)
    end
    return copied, nil
end

local function loadCreationRequest(tx, requestId, lock)
    local suffix = lock and ' FOR UPDATE' or ''
    local row = tx.one([[SELECT `request`.`id`, `request`.`public_id`,
            `request`.`group_type_id`, `request`.`requested_by_ref`,
            `request`.`idempotency_key`, `request`.`requested_slug`,
            `request`.`request_json`, `request`.`required_approvals`,
            `request`.`approval_count`, `request`.`creator_permission`,
            `request`.`approval_permission`, `request`.`type_schema_version`,
            `request`.`type_version`, `request`.`status`,
            `target`.`public_id` AS `target_group_public_id`,
            `request`.`failure_code`, `request`.`execution_attempts`,
            `request`.`version`,
            (`request`.`expires_at` <= CURRENT_TIMESTAMP(6)) AS `is_expired`,
            DATE_FORMAT(`request`.`expires_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `expires_at`,
            DATE_FORMAT(`request`.`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`,
            DATE_FORMAT(`request`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`,
            `type_record`.`type_key`, `type_record`.`status` AS `type_status`,
            `type_record`.`schema_version` AS `current_type_schema_version`,
            `type_record`.`version` AS `current_type_version`,
            `type_record`.`create_permission` AS `current_creator_permission`,
            `type_record`.`required_approvals` AS `current_required_approvals`,
            `type_record`.`approval_permission` AS `current_approval_permission`
        FROM `synex_group_creation_requests` AS `request`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `request`.`group_type_id`
        LEFT JOIN `synex_groups` AS `target`
            ON `target`.`id` = `request`.`target_group_id`
        WHERE `request`.`public_id` = ?]] .. suffix, { requestId })
    if not row then
        return nil, Foundation.domainError('CREATION_REQUEST_NOT_FOUND',
            'The organization creation request does not exist.')
    end
    local version = validVersion(row.version)
    local required = tonumber(row.required_approvals)
    local approvals = tonumber(row.approval_count)
    if not version or not required or math.type(required) ~= 'integer'
        or required < 1 or required > 32 or not approvals
        or math.type(approvals) ~= 'integer' or approvals < 0 or approvals > required
        or type(row.status) ~= 'string' or type(row.requested_by_ref) ~= 'string'
        or type(row.type_key) ~= 'string' or type(row.requested_slug) ~= 'string'
        or type(row.creator_permission) ~= 'string'
        or type(row.approval_permission) ~= 'string' then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The persisted organization creation state is invalid.', true)
    end
    row.version = version
    row.required_approvals = required
    row.approval_count = approvals
    row.is_expired = tonumber(row.is_expired) == 1
    return row, nil
end

local function decisions(tx, internalId, expectedPermission)
    local rows = tx.many([[SELECT `public_id`, `approver_character_ref`, `decision`,
            `permission_name`, `request_version`,
            DATE_FORMAT(`created_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `created_at`
        FROM `synex_group_creation_approvals`
        WHERE `creation_request_id` = ? ORDER BY `id` ASC LIMIT 33]], { internalId })
    if type(rows) ~= 'table' or #rows > 32 then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The organization creation decision set is invalid.', true)
    end
    local result = {}
    local seenCharacters = {}
    for index, row in ipairs(rows) do
        local requestVersion = validVersion(row.request_version)
        if not Foundation.isPublicId(row.public_id)
            or not Foundation.isPublicId(row.approver_character_ref)
            or seenCharacters[row.approver_character_ref]
            or (row.decision ~= 'approved' and row.decision ~= 'rejected')
            or expectedPermission ~= nil and row.permission_name ~= expectedPermission
            or requestVersion ~= index then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'A persisted organization creation decision is invalid.', true)
        end
        seenCharacters[row.approver_character_ref] = true
        result[index] = {
            decision_id = row.public_id,
            character_id = row.approver_character_ref,
            decision = row.decision,
            created_at = tostring(row.created_at)
        }
    end
    return result, nil
end

local function validateDecisionState(row, storedDecisions)
    local approved, rejectedCount = 0, 0
    for _, decision in ipairs(storedDecisions) do
        if decision.decision == 'approved' then approved = approved + 1
        else rejectedCount = rejectedCount + 1 end
    end
    local valid = approved == row.approval_count
        and ((row.status == 'pending' and rejectedCount == 0
                and approved < row.required_approvals)
            or (row.status == 'approved' and rejectedCount == 0
                and approved == row.required_approvals)
            or (row.status == 'executed' and rejectedCount == 0
                and approved == row.required_approvals)
            or (row.status == 'rejected' and rejectedCount == 1)
            or (row.status == 'expired' and rejectedCount == 0))
    if valid then return true, nil end
    return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
        'The organization creation decision journal is inconsistent.', true)
end

local function view(tx, row)
    local storedDecisions, decisionError = decisions(
        tx, row.id, row.approval_permission)
    if not storedDecisions then return nil, decisionError end
    local consistent, consistencyError = validateDecisionState(row, storedDecisions)
    if not consistent then return nil, consistencyError end
    return {
        creation_request_id = row.public_id,
        requested_by_character_id = row.requested_by_ref,
        group_type = row.type_key,
        slug = row.requested_slug,
        status = row.status,
        required_approvals = row.required_approvals,
        approval_count = row.approval_count,
        expires_at = tostring(row.expires_at),
        target_group_id = row.target_group_public_id,
        failure_code = row.failure_code,
        version = row.version,
        decisions = storedDecisions
    }, nil
end

local function permitted(runtime, characterId, permission)
    if type(runtime.checkCorePermission) ~= 'function' then
        return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'The Core character permission boundary is unavailable.', true)
    end
    local allowed, permissionError = runtime.checkCorePermission(characterId, permission)
    if allowed then return true, nil end
    return nil, permissionError or Foundation.domainError('INSUFFICIENT_PERMISSION',
        'The character lacks organization creation approval authority.')
end

function read.creation_requests_get(tx, request, runtime)
    local row, rowError = loadCreationRequest(tx, request.creation_request_id, false)
    if not row then return nil, rowError, nil end
    if request.actor_character_id ~= row.requested_by_ref then
        local allowed, permissionError = permitted(
            runtime, request.actor_character_id, row.approval_permission)
        if not allowed then
            if type(permissionError) == 'table' and permissionError.retryable == true then
                return rejected('DATABASE_ERROR',
                    'Organization creation approval authority is temporarily unavailable.', true)
            end
            return rejected('CREATION_REQUEST_NOT_FOUND',
                'The organization creation request does not exist.')
        end
    end
    local result, viewError = view(tx, row)
    return result, viewError, nil
end

function read.creation_requests_execution_context(tx, request, runtime)
    if type(request) ~= 'table'
        or not Foundation.isPublicId(request.creation_request_id) then
        return rejected('VALIDATION_FAILED',
            'The organization creation execution identity is invalid.')
    end
    local row, rowError = loadCreationRequest(tx, request.creation_request_id, false)
    if not row then return nil, rowError, nil end
    if row.status ~= 'approved' then
        return rejected('CREATION_REQUEST_NOT_READY',
            'The organization creation request has not reached approval quorum.')
    end
    if row.is_expired then
        return rejected('CREATION_REQUEST_EXPIRED',
            'The approved organization creation request has expired.')
    end
    local original, decodeError = decodeRequest(runtime, row.request_json)
    if not original then return nil, decodeError, nil end
    if original.actor_character_id ~= row.requested_by_ref
        or original.type ~= row.type_key or original.slug ~= row.requested_slug
        or original.idempotency_key ~= row.idempotency_key then
        return rejected('DATABASE_RESULT_INVALID',
            'The approved organization request does not match its journal.', true)
    end
    local storedDecisions, decisionError = decisions(
        tx, row.id, row.approval_permission)
    if not storedDecisions then return nil, decisionError, nil end
    local consistent, consistencyError = validateDecisionState(row, storedDecisions)
    if not consistent then return nil, consistencyError, nil end
    if #storedDecisions ~= row.required_approvals then
        return rejected('DATABASE_RESULT_INVALID',
            'The approved organization request has an inconsistent quorum.', true)
    end
    local approvers = {}
    for index, decision in ipairs(storedDecisions) do
        if decision.decision ~= 'approved' then
            return rejected('DATABASE_RESULT_INVALID',
                'The approved organization request contains a rejecting decision.', true)
        end
        approvers[index] = decision.character_id
    end
    return {
        creationRequestId = row.public_id,
        version = row.version,
        request = original,
        requestedByCharacterId = row.requested_by_ref,
        creatorPermission = row.creator_permission,
        approvalPermission = row.approval_permission,
        requiredApprovals = row.required_approvals,
        approverCharacterIds = approvers,
        groupTypeId = tonumber(row.group_type_id),
        typeSchemaVersion = tonumber(row.type_schema_version),
        typeVersion = tonumber(row.type_version)
    }, nil, nil
end

function read.creation_requests_reconcile(tx, request)
    local maximum = type(request) == 'table' and tonumber(request.maximum) or nil
    if not maximum or math.type(maximum) ~= 'integer' or maximum < 1 or maximum > 32 then
        return rejected('VALIDATION_FAILED',
            'The organization creation reconciliation limit is invalid.')
    end
    local rows = tx.many([[SELECT `public_id`,
            CASE WHEN `expires_at` <= CURRENT_TIMESTAMP(6) THEN 'expire' ELSE 'execute' END AS `action`
        FROM `synex_group_creation_requests`
        WHERE (`status` = 'approved')
            OR (`status` = 'pending' AND `expires_at` <= CURRENT_TIMESTAMP(6))
        ORDER BY CASE WHEN `expires_at` <= CURRENT_TIMESTAMP(6) THEN 0 ELSE 1 END,
            `updated_at`, `id` LIMIT ?]], { maximum })
    if type(rows) ~= 'table' or #rows > maximum then
        return rejected('DATABASE_RESULT_INVALID',
            'The organization creation reconciliation batch is invalid.', true)
    end
    local result = {}
    for index, row in ipairs(rows) do
        if not Foundation.isPublicId(row.public_id)
            or (row.action ~= 'expire' and row.action ~= 'execute') then
            return rejected('DATABASE_RESULT_INVALID',
                'An organization creation reconciliation item is invalid.', true)
        end
        result[index] = { creationRequestId = row.public_id, action = row.action }
    end
    return result, nil, nil
end

local function decide(tx, request, runtime, decision, context)
    local row, rowError = loadCreationRequest(tx, request.creation_request_id, true)
    if not row then return nil, rowError, nil end
    local allowed, permissionError = permitted(
        runtime, request.actor_character_id, row.approval_permission)
    if not allowed then return nil, permissionError, nil end
    if row.requested_by_ref == request.actor_character_id then
        return rejected('CREATOR_CANNOT_DECIDE',
            'The organization creator cannot decide their own request.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if row.version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization creation request version has changed.', true, {
                expected = request.expected_version,
                actual = row.version
            })
    end
    if row.status ~= 'pending' then
        return rejected('CREATION_REQUEST_TERMINAL',
            'The organization creation request no longer accepts decisions.')
    end
    if row.is_expired then
        return rejected('CREATION_REQUEST_EXPIRED',
            'The organization creation request has expired.')
    end
    local storedDecisions, decisionError = decisions(
        tx, row.id, row.approval_permission)
    if not storedDecisions then return nil, decisionError, nil end
    local consistent, consistencyError = validateDecisionState(row, storedDecisions)
    if not consistent then return nil, consistencyError, nil end
    if tx.one([[SELECT `id` FROM `synex_group_creation_approvals`
        WHERE `creation_request_id` = ? AND `approver_character_ref` = ? FOR UPDATE]], {
        row.id, request.actor_character_id
    }) then
        return rejected('APPROVAL_ALREADY_DECIDED',
            'The character already decided this organization creation request.')
    end
    local decisionId, decisionIdError = checkedId(runtime, 'groups_approval')
    if not decisionId then return nil, decisionIdError, nil end
    local reason, reasonError = checkedReason(runtime, request.reason,
        decision == 'approved' and 'group_creation_approved'
            or 'group_creation_rejected')
    if not reason then return nil, reasonError, nil end
    if affectedRows(tx.query([[INSERT INTO `synex_group_creation_approvals`
        (`public_id`, `creation_request_id`, `approver_character_ref`, `decision`,
         `permission_name`, `request_version`, `reason_code`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)]], {
        decisionId, row.id, request.actor_character_id, decision,
        row.approval_permission, row.version, reason
    })) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization creation decision could not be persisted.', true)
    end
    local nextApprovalCount = row.approval_count + (decision == 'approved' and 1 or 0)
    local nextStatus = decision == 'rejected' and 'rejected'
        or nextApprovalCount == row.required_approvals and 'approved' or 'pending'
    local changed = tx.affected([[UPDATE `synex_group_creation_requests`
        SET `approval_count` = ?, `status` = ?,
            `approved_at` = CASE WHEN ? = 'approved'
                THEN CURRENT_TIMESTAMP(6) ELSE `approved_at` END,
            `completed_at` = CASE WHEN ? = 'rejected'
                THEN CURRENT_TIMESTAMP(6) ELSE `completed_at` END,
            `version` = `version` + 1
        WHERE `id` = ? AND `version` = ? AND `status` = 'pending'
            AND `approval_count` = ? AND `expires_at` > CURRENT_TIMESTAMP(6)]], {
        nextApprovalCount, nextStatus, nextStatus, nextStatus,
        row.id, row.version, row.approval_count
    })
    if changed ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization creation request changed during the decision.', true)
    end
    if nextStatus == 'rejected' then
        local released, releaseError = releaseSlugReservation(
            tx, row.requested_slug, 'creation_request', row.public_id)
        if not released then return nil, releaseError, nil end
    end
    local after = {
        creation_request_id = row.public_id,
        decision_id = decisionId,
        decision = decision,
        status = nextStatus,
        approval_count = nextApprovalCount,
        required_approvals = row.required_approvals,
        version = row.version + 1
    }
    local effect = runtime.effect('group.creation_' .. decision,
        'group_creation_request', row.public_id, nil,
        request.actor_character_id,
        { status = 'pending', approval_count = row.approval_count, version = row.version },
        after, reason, row.version + 1)
    return {
        creation_request_id = row.public_id,
        decision_id = decisionId,
        status = nextStatus,
        approval_count = nextApprovalCount,
        required_approvals = row.required_approvals,
        version = row.version + 1,
        replayed = false
    }, nil, { effect }
end

function execute.creation_requests_approve(tx, request, runtime, context)
    return decide(tx, request, runtime, 'approved', context)
end

function execute.creation_requests_reject(tx, request, runtime, context)
    return decide(tx, request, runtime, 'rejected', context)
end

function execute.creation_requests_execute(tx, request, runtime, context)
    if type(request) ~= 'table'
        or not Foundation.isPublicId(request.creation_request_id)
        or type(request.idempotency_key) ~= 'string'
        or request.idempotency_key ~= 'creation-exec:' .. request.creation_request_id
        or not validVersion(request.expected_version) then
        return rejected('VALIDATION_FAILED',
            'The approved organization execution request is invalid.')
    end
    local row, rowError = loadCreationRequest(tx, request.creation_request_id, true)
    if not row then return nil, rowError, nil end
    if row.status == 'executed' and row.target_group_public_id then
        return {
            entity_id = row.target_group_public_id,
            entity_type = 'group',
            status = 'active',
            version = 1,
            replayed = true
        }, nil, {}
    end
    if row.version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION',
            'The approved organization request version has changed.', true)
    end
    if row.status ~= 'approved' then
        return rejected('CREATION_REQUEST_NOT_READY',
            'The organization creation request is not executable.')
    end
    if row.is_expired then
        return rejected('CREATION_REQUEST_EXPIRED',
            'The approved organization creation request has expired.')
    end
    local storedDecisions, decisionError = decisions(
        tx, row.id, row.approval_permission)
    if not storedDecisions then return nil, decisionError, nil end
    local consistent, consistencyError = validateDecisionState(row, storedDecisions)
    if not consistent then return nil, consistencyError, nil end
    if #storedDecisions ~= row.required_approvals then
        return rejected('DATABASE_RESULT_INVALID',
            'The approved organization request has an inconsistent quorum.', true)
    end
    for _, item in ipairs(storedDecisions) do
        if item.decision ~= 'approved' then
            return rejected('DATABASE_RESULT_INVALID',
                'The approved organization request contains a rejection.', true)
        end
    end
    local original, decodeError = decodeRequest(runtime, row.request_json)
    if not original then return nil, decodeError, nil end
    if original.actor_character_id ~= row.requested_by_ref
        or original.type ~= row.type_key or original.slug ~= row.requested_slug
        or original.idempotency_key ~= row.idempotency_key then
        return rejected('DATABASE_RESULT_INVALID',
            'The approved organization request does not match its journal.', true)
    end
    local executionContext = {}
    for key, value in pairs(context or {}) do executionContext[key] = value end
    executionContext.approvedCreation = {
        creationRequestId = row.public_id,
        permissionsRevalidated = request.permissions_revalidated == true,
        groupTypeId = row.group_type_id,
        typeSchemaVersion = row.type_schema_version,
        typeVersion = row.type_version,
        creatorPermission = row.creator_permission,
        requiredApprovals = row.required_approvals,
        approvalPermission = row.approval_permission
    }
    local created, creationError, effects = OrganizationsLifecycle.execute.create(
        tx, original, runtime, executionContext)
    if not created then return nil, creationError, nil end
    local target = tx.one([[SELECT `id` FROM `synex_groups`
        WHERE `public_id` = ? FOR UPDATE]], { created.entity_id })
    if not target then
        return rejected('DATABASE_RESULT_INVALID',
            'The approved organization could not be linked to its request.', true)
    end
    local changed = tx.affected([[UPDATE `synex_group_creation_requests`
        SET `status` = 'executed', `target_group_id` = ?, `failure_code` = NULL,
            `execution_attempts` = `execution_attempts` + 1,
            `last_attempt_at` = CURRENT_TIMESTAMP(6),
            `completed_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
        WHERE `id` = ? AND `version` = ? AND `status` = 'approved'
            AND `approval_count` = `required_approvals`
            AND `expires_at` > CURRENT_TIMESTAMP(6)]], {
        target.id, row.id, row.version
    })
    if changed ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The approved organization request changed during execution.', true)
    end
    local reason, reasonError = checkedReason(runtime, nil, 'group_creation_executed')
    if not reason then return nil, reasonError, nil end
    effects = type(effects) == 'table' and effects or {}
    effects[#effects + 1] = runtime.effect('group.creation_executed',
        'group_creation_request', row.public_id, created.entity_id,
        row.requested_by_ref,
        { status = 'approved', version = row.version },
        { status = 'executed', target_group_id = created.entity_id,
            version = row.version + 1 },
        reason, row.version + 1)
    return created, nil, effects
end

function execute.creation_requests_expire(tx, request, runtime)
    if type(request) ~= 'table'
        or not Foundation.isPublicId(request.creation_request_id)
        or type(request.idempotency_key) ~= 'string'
        or request.idempotency_key ~= 'creation-expire:' .. request.creation_request_id then
        return rejected('VALIDATION_FAILED',
            'The organization creation expiry request is invalid.')
    end
    local row, rowError = loadCreationRequest(tx, request.creation_request_id, true)
    if not row then return nil, rowError, nil end
    if row.status == 'expired' then
        return {
            entity_id = row.public_id,
            entity_type = 'group_creation_request',
            status = 'expired',
            version = row.version,
            replayed = true
        }, nil, {}
    end
    if row.status ~= 'pending' and row.status ~= 'approved' then
        return rejected('CREATION_REQUEST_TERMINAL',
            'The organization creation request is already terminal.')
    end
    if not row.is_expired then
        return rejected('CREATION_REQUEST_NOT_READY',
            'The organization creation request has not expired.')
    end
    local changed = tx.affected([[UPDATE `synex_group_creation_requests`
        SET `status` = 'expired', `failure_code` = 'CREATION_REQUEST_EXPIRED',
            `completed_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
        WHERE `id` = ? AND `version` = ? AND `status` IN ('pending', 'approved')
            AND `expires_at` <= CURRENT_TIMESTAMP(6)]], { row.id, row.version })
    if changed ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization creation request changed during expiry.', true)
    end
    local released, releaseError = releaseSlugReservation(
        tx, row.requested_slug, 'creation_request', row.public_id)
    if not released then return nil, releaseError, nil end
    local reason, reasonError = checkedReason(runtime, nil, 'group_creation_expired')
    if not reason then return nil, reasonError, nil end
    local effect = runtime.effect('group.creation_expired',
        'group_creation_request', row.public_id, nil, nil,
        { status = row.status, version = row.version },
        { status = 'expired', version = row.version + 1 },
        reason, row.version + 1)
    return {
        entity_id = row.public_id,
        entity_type = 'group_creation_request',
        status = 'expired',
        version = row.version + 1,
        replayed = false
    }, nil, { effect }
end

return { read = read, execute = execute }
end
