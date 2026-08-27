return function(Foundation)
local domainError = Foundation.domainError

local GROUP_VISIBILITY = { public = true, internal = true, private = true, hidden = true }
local RELATIONSHIP_STATUS = { active = true, suspended = true, ended = true }
local GRADE_STATUS = { active = true, disabled = true }
local ROLE_STATUS = { active = true, disabled = true, retired = true }
local ACYCLIC_RELATIONSHIPS = { subdivision_of = true, subsidiary_of = true }
local MAXIMUM_HIERARCHY_DEPTH = 64
local MAXIMUM_METADATA_BYTES = 1048576

local function rejected(code, message, retryable, details)
    return nil, domainError(code, message, retryable, details), nil
end

local function affectedRows(value)
    if type(value) == 'table' then
        return tonumber(value.affectedRows or value.affected_rows)
    end
    return tonumber(value)
end

local function checkedId(runtime, namespace)
    local value, idError = runtime.id(namespace)
    if value == false then value = nil end
    if not Foundation.isPublicId(value) then
        return nil, idError or domainError('ID_ALLOCATION_FAILED',
            'A public organization identifier could not be allocated.', true)
    end
    return value, nil
end

local function checkedReason(runtime, value, fallback)
    local reason, reasonError = runtime.reason(value, fallback)
    if reason == false then reason = nil end
    if type(reason) ~= 'string' or #reason < 2 or #reason > 64
        or reason:match('^[a-z][a-z0-9_.:%-]*$') == nil then
        return nil, reasonError or domainError('REASON_INVALID',
            'The reason could not be represented as a bounded reason code.')
    end
    return reason, nil
end

local function authorize(runtime, tx, groupId, actorCharacterId, capability,
    policyContext, scope)
    local decision, authorizationError = runtime.authorize(
        tx, groupId, actorCharacterId, capability, scope or 'group', policyContext)
    if decision == true or (type(decision) == 'table' and decision.allowed ~= false) then
        return true, nil
    end
    return nil, authorizationError or domainError('INSUFFICIENT_PERMISSION',
        'The actor is not authorized for this organization operation.')
end

local function decodeMetadata(runtime, encoded)
    if type(encoded) ~= 'string' or #encoded > MAXIMUM_METADATA_BYTES then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored organization metadata is invalid.')
    end
    local decodedOk, decoded = pcall(runtime.jsonDecode, encoded)
    if not decodedOk or type(decoded) ~= 'table'
        or Foundation.jsonContainerKind(decoded) == 'array' then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored organization metadata is invalid.')
    end
    for key in next, decoded do
        if type(key) ~= 'string' then
            return nil, domainError('DATABASE_RESULT_INVALID',
                'The stored organization metadata is not an object.')
        end
    end
    local copiedOk, copied = pcall(Foundation.copyPlain, decoded, {
        maximumDepth = 8, maximumKeys = 128,
        maximumStringBytes = 4096, preserveContainerKind = false
    })
    if not copiedOk then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored organization metadata exceeds its supported bound.')
    end
    return copied, nil
end

local function encodeMetadata(runtime, metadata)
    local encodedOk, encoded = pcall(
        Foundation.createCanonicalEncoder(runtime.jsonEncode), metadata)
    if not encodedOk or type(encoded) ~= 'string' or #encoded > MAXIMUM_METADATA_BYTES then
        return nil, domainError('JSON_ENCODING_FAILED',
            'The organization metadata could not be encoded.')
    end
    return encoded, nil
end

local function groupView(runtime, row, includeDescription)
    local version = tonumber(row.version)
    if not version or math.type(version) ~= 'integer' or version < 1 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored organization version is invalid.')
    end
    local result = {
        group_id = row.group_public_id,
        type = row.type_key,
        parent_group_id = row.parent_public_id,
        slug = row.slug,
        name = row.name,
        label = row.label,
        status = type(row.lifecycle_state) == 'string'
            and row.lifecycle_state:lower() or row.status,
        visibility = row.visibility,
        dynamic = tonumber(row.dynamic) == 1,
        version = version,
        created_at = tostring(row.created_at),
        updated_at = tostring(row.updated_at)
    }
    if includeDescription then
        result.description = row.description
    end
    return result, nil
end

local function loadGroupForUpdate(tx, groupPublicId)
    local row = tx.one([[SELECT `group_record`.`id`, `group_record`.`public_id` AS `group_public_id`,
            `group_record`.`group_key`, `group_record`.`display_name`, `group_record`.`status`,
            `group_record`.`metadata_json`, `group_record`.`version`,
            `profile`.`group_type_id`, `profile`.`slug`, `profile`.`name`, `profile`.`label`,
            `profile`.`description`, `profile`.`dynamic`, `profile`.`metadata_json` AS `profile_metadata_json`,
            `profile`.`visibility`, `profile`.`creation_source`, `profile`.`lifecycle_state`,
            `profile`.`state_changed_at`, `profile`.`suspended_at`, `profile`.`archived_at`,
            `profile`.`deleted_at`,
            `profile`.`version` AS `profile_version`,
            `type_record`.`type_key`, `type_record`.`hierarchy_enabled`,
            `type_record`.`relationships_enabled`
        FROM `synex_groups` AS `group_record`
        INNER JOIN `synex_group_organization_profiles` AS `profile`
            ON `profile`.`group_id` = `group_record`.`id`
        INNER JOIN `synex_group_types` AS `type_record`
            ON `type_record`.`id` = `profile`.`group_type_id`
        WHERE `group_record`.`public_id` = ? FOR UPDATE]], { groupPublicId })
    if not row then
        return nil, domainError('GROUP_NOT_FOUND', 'The organization does not exist.')
    end
    local version = tonumber(row.version)
    local profileVersion = tonumber(row.profile_version)
    if not version or math.type(version) ~= 'integer' or version < 1
        or profileVersion ~= version then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The organization version state is inconsistent.')
    end
    row.version = version
    row.profile_version = profileVersion
    return row, nil
end

local function loadSlugReservation(tx, slug)
    local row = tx.one([[SELECT `owner_kind`, `owner_public_id`, `version`
        FROM `synex_group_slug_reservations` WHERE `slug` = ? FOR UPDATE]], { slug })
    if not row then return nil, nil end
    local version = tonumber(row.version)
    if (row.owner_kind ~= 'group' and row.owner_kind ~= 'creation_request')
        or not Foundation.isPublicId(row.owner_public_id)
        or not version or math.type(version) ~= 'integer' or version < 1 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The stored organization slug reservation is invalid.', true)
    end
    row.version = version
    return row, nil
end

local function reserveSlug(tx, slug, ownerKind, ownerPublicId)
    local result = tx.query([[INSERT IGNORE INTO `synex_group_slug_reservations`
        (`slug`, `owner_kind`, `owner_public_id`, `version`)
        VALUES (?, ?, ?, 1)]], { slug, ownerKind, ownerPublicId })
    local changed = affectedRows(result)
    if changed == 1 then return { version = 1 }, nil end
    if changed ~= 0 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The organization slug reservation returned an invalid result.', true)
    end
    local existing, existingError = loadSlugReservation(tx, slug)
    if existingError then return nil, existingError end
    if not existing then
        return nil, domainError('CONCURRENT_MODIFICATION',
            'The organization slug reservation changed concurrently.', true)
    end
    if existing.owner_kind == ownerKind and existing.owner_public_id == ownerPublicId then
        return existing, nil
    end
    return nil, domainError('GROUP_EXISTS',
        'An organization or active creation request already uses this slug.')
end

local function requireSlugReservation(tx, slug, ownerKind, ownerPublicId)
    local existing, existingError = loadSlugReservation(tx, slug)
    if existingError then return nil, existingError end
    if not existing or existing.owner_kind ~= ownerKind
        or existing.owner_public_id ~= ownerPublicId then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The organization slug reservation does not match its durable owner.', true)
    end
    return existing, nil
end

local function transferSlugReservation(tx, slug, fromKind, fromPublicId,
    toKind, toPublicId, expectedVersion)
    local changed = tx.affected([[UPDATE `synex_group_slug_reservations`
        SET `owner_kind` = ?, `owner_public_id` = ?, `version` = `version` + 1
        WHERE `slug` = ? AND `owner_kind` = ? AND `owner_public_id` = ?
            AND `version` = ?]], {
        toKind, toPublicId, slug, fromKind, fromPublicId, expectedVersion
    })
    if changed ~= 1 then
        return nil, domainError('CONCURRENT_MODIFICATION',
            'The organization slug reservation changed during ownership transfer.', true)
    end
    return true, nil
end

local function releaseSlugReservation(tx, slug, ownerKind, ownerPublicId)
    local changed = tx.affected([[DELETE FROM `synex_group_slug_reservations`
        WHERE `slug` = ? AND `owner_kind` = ? AND `owner_public_id` = ?]],
        { slug, ownerKind, ownerPublicId })
    if changed ~= 1 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The organization slug reservation could not be released.', true)
    end
    return true, nil
end

local function bumpReadModel(tx, groupInternalId)
    local result = tx.query([[UPDATE `synex_group_read_model_versions`
        SET `model_version` = `model_version` + 1,
            `invalidated_at` = CURRENT_TIMESTAMP(6)
        WHERE `group_id` = ?]], { groupInternalId })
    if affectedRows(result) ~= 1 then
        return nil, domainError('DATABASE_RESULT_INVALID',
            'The organization read model could not be invalidated.', true)
    end
    return true, nil
end

local function mutationResult(runtime, entityId, entityType, status, version, effect)
    local value = runtime.success(entityId, entityType, status, version)
    if type(value) ~= 'table' then
        return rejected('RUNTIME_RESULT_INVALID',
            'The organization runtime returned an invalid mutation result.', true)
    end
    return value, nil, effect and { effect } or {}
end

return {
    GROUP_VISIBILITY = GROUP_VISIBILITY,
    RELATIONSHIP_STATUS = RELATIONSHIP_STATUS,
    GRADE_STATUS = GRADE_STATUS,
    ROLE_STATUS = ROLE_STATUS,
    ACYCLIC_RELATIONSHIPS = ACYCLIC_RELATIONSHIPS,
    MAXIMUM_HIERARCHY_DEPTH = MAXIMUM_HIERARCHY_DEPTH,
    rejected = rejected,
    affectedRows = affectedRows,
    checkedId = checkedId,
    checkedReason = checkedReason,
    authorize = authorize,
    decodeMetadata = decodeMetadata,
    encodeMetadata = encodeMetadata,
    groupView = groupView,
    loadGroupForUpdate = loadGroupForUpdate,
    loadSlugReservation = loadSlugReservation,
    reserveSlug = reserveSlug,
    requireSlugReservation = requireSlugReservation,
    transferSlugReservation = transferSlugReservation,
    releaseSlugReservation = releaseSlugReservation,
    bumpReadModel = bumpReadModel,
    mutationResult = mutationResult,
}
end
