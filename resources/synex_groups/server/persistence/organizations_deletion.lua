return function(Foundation)
local Shared = require('server.persistence.organizations_shared')(Foundation)
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local affectedRows = Shared.affectedRows
local loadGroupForUpdate = Shared.loadGroupForUpdate
local rejected = Shared.rejected
local execute = {}

function execute.delete(tx, request, runtime, context)
    if type(runtime.checkCorePermission) ~= 'function' then
        return rejected('CORE_UNAVAILABLE',
            'The Core character permission boundary is unavailable.', true)
    end
    local permitted, permissionError = runtime.checkCorePermission(
        request.actor_character_id, 'synex.groups.delete')
    if not permitted then
        return nil, permissionError or Foundation.domainError(
            'INSUFFICIENT_PERMISSION',
            'The actor character may not request organization deletion.'), nil
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = loadGroupForUpdate(tx, request.group_id)
    if not group then return nil, groupError, nil end
    if group.version ~= tonumber(request.expected_version) then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization version has changed.', true, {
                expected = request.expected_version,
                actual = group.version
            })
    end
    if group.status ~= 'archived' or group.lifecycle_state ~= 'ARCHIVED'
        or group.archived_at == nil or group.deleted_at ~= nil then
        return rejected('GROUP_NOT_ARCHIVED',
            'An organization must be archived before deletion can be coordinated.')
    end
    local current = tx.one([[SELECT `public_id`, `state`, `version`
        FROM `synex_group_deletion_requests`
        WHERE `group_id` = ? AND `state` IN ('planning', 'dissolving')
        LIMIT 1 FOR UPDATE]], { group.id })
    if current then
        return rejected('GROUP_DELETION_IN_PROGRESS',
            'An organization deletion request is already active.', false, {
                deletion_request_id = current.public_id,
                state = current.state,
                version = tonumber(current.version)
            })
    end
    local requestId, requestIdError = checkedId(runtime, 'groups_deletion')
    if not requestId then return nil, requestIdError, nil end
    local reasonCode, reasonError = checkedReason(
        runtime, request.reason, 'group_deletion_requested')
    if not reasonCode then return nil, reasonError, nil end
    local inserted = tx.query([[INSERT INTO `synex_group_deletion_requests`
        (`public_id`, `group_id`, `idempotency_key`, `actor_ref`, `reason_code`,
         `reason_text`, `state`, `requested_group_version`, `group_version`, `version`)
        VALUES (?, ?, ?, ?, ?, ?, 'planning', ?, ?, 1)]], {
        requestId, group.id, request.idempotency_key, request.actor_character_id,
        reasonCode, request.reason, group.version, group.version
    })
    if affectedRows(inserted) ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The organization deletion request could not be persisted.', true)
    end
    local after = {
        deletion_request_id = requestId,
        group_id = request.group_id,
        state = 'planning',
        group_status = 'archived',
        group_version = group.version,
        version = 1
    }
    local effect = runtime.effect('group.deletion_requested', 'deletion_request',
        requestId, request.group_id, request.actor_character_id, nil, after,
        reasonCode, 1)
    return {
        deletion_request_id = requestId,
        group_id = request.group_id,
        state = 'planning',
        group_status = 'archived',
        group_version = group.version,
        version = 1,
        replayed = false
    }, nil, { effect }
end

return { execute = execute }
end
