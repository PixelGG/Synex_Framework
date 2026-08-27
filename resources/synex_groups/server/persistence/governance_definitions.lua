return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local DEFINITION_KINDS = Shared.DEFINITION_KINDS
local rejected = Shared.rejected
local isObject = Shared.isObject
local arrayLength = Shared.arrayLength
local publicId = Shared.publicId
local canonical = Shared.canonical
local copyJson = Shared.copyJson
local ownerContext = Shared.ownerContext
local GroupDefinitions = require('server.persistence.governance_definitions_groups')(Foundation)
local handlers = { read = {}, execute = {} }

local function definitionIdentity(value)
    if not isObject(value) then
        return nil, nil, Foundation.domainError('VALIDATION_FAILED',
            'Each static definition must be an object.')
    end
    local key = value.key
    local kind = value.kind or 'group'
    if type(key) ~= 'string' or #key < 2 or #key > 96
        or not key:match('^[a-z][a-z0-9_.:%-]*$')
        or not DEFINITION_KINDS[kind] then
        return nil, nil, Foundation.domainError('VALIDATION_FAILED',
            'Each static definition requires a valid key and supported kind.')
    end
    return key, kind, nil
end

function handlers.execute.definitions_sync(tx, request, runtime, context)
    local valid, validationError = runtime.validateOperation('definitions_sync', request)
    if not valid then return nil, validationError end
    local owner, _, ownerError = ownerContext(context, request.owner_resource)
    if not owner then return nil, ownerError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local count = arrayLength(request.definitions, 16)
    if count == nil then
        return rejected('VALIDATION_FAILED',
            'definitions must be a bounded dense array.')
    end

    local plan, byKey = {}, {}
    for index = 1, count do
        local definition, copyError = copyJson(request.definitions[index], {
            maximumDepth = 8,
            maximumKeys = 256,
            maximumStringBytes = 4096,
            preserveContainerKind = false
        })
        if not definition then return nil, copyError end
        local key, kind, identityError = definitionIdentity(definition)
        if not key then return nil, identityError end
        if byKey[key] then
            return rejected('VALIDATION_FAILED',
                'Static definition keys must be unique within a synchronization request.')
        end
        if kind == 'group' then
            definition, identityError = GroupDefinitions.normalize(definition)
            if not definition then return nil, identityError end
        end
        local encoded, encodeError = canonical(runtime, definition)
        if not encoded then return nil, encodeError end
        if #encoded > 65536 then
            return rejected('VALIDATION_FAILED',
                'A static definition exceeds 64 KiB.')
        end
        local digestRow = tx.one('SELECT LOWER(SHA2(?, 256)) AS digest', { encoded })
        local digest = digestRow and digestRow.digest
        if type(digest) ~= 'string' or #digest ~= 64 or not digest:match('^[0-9a-f]+$') then
            return rejected('DATABASE_ERROR',
                'A static definition digest could not be calculated.', true)
        end
        local item = {
            key = key,
            kind = kind,
            definition = definition,
            group = kind == 'group' and definition or nil,
            encoded = encoded,
            digest = digest
        }
        byKey[key] = item
        plan[index] = item
    end

    local existingRows = tx.many([[SELECT id, public_id, definition_key, target_group_id,
            schema_version, definition_json, definition_digest,
            LOWER(SHA2(definition_json, 256)) AS stored_definition_digest,
            applied_digest,
            applied_definition_json,
            LOWER(SHA2(applied_definition_json, 256)) AS applied_snapshot_digest,
            state, version
        FROM synex_group_definition_sets
        WHERE owner_resource = ? ORDER BY definition_key ASC LIMIT 101 FOR UPDATE]], { owner })
    if #existingRows > 100 then
        return rejected('DATABASE_ERROR',
            'The owner definition set exceeds the supported bound.', true)
    end
    local existingByKey = {}
    for _, row in ipairs(existingRows) do
        if row.stored_definition_digest ~= row.definition_digest then
            return rejected('DATABASE_ERROR',
                'A stored static definition digest is inconsistent.', true)
        end
        local decodedOk, decoded = pcall(runtime.jsonDecode, row.definition_json)
        if not decodedOk or type(decoded) ~= 'table' then
            return rejected('DATABASE_ERROR',
                'A stored static definition is invalid.', true)
        end
        local copied = copyJson(decoded)
        if not copied then
            return rejected('DATABASE_ERROR',
                'A stored static definition exceeds supported bounds.', true)
        end
        local storedKey, kind = definitionIdentity(copied)
        if storedKey ~= row.definition_key or kind == nil then
            return rejected('DATABASE_ERROR',
                'A stored static definition identity is inconsistent.', true)
        end
        row.definition_kind = kind
        if row.applied_definition_json ~= nil then
            if row.applied_snapshot_digest ~= row.applied_digest then
                return rejected('DATABASE_ERROR',
                    'A stored applied static definition digest is inconsistent.', true)
            end
            local appliedOk, applied = pcall(runtime.jsonDecode, row.applied_definition_json)
            local appliedCopy = appliedOk and copyJson(applied) or nil
            local appliedKey, appliedKind
            if appliedCopy then appliedKey, appliedKind = definitionIdentity(appliedCopy) end
            if appliedKey ~= row.definition_key or appliedKind == nil then
                return rejected('DATABASE_ERROR',
                    'A stored applied static definition snapshot is invalid.', true)
            end
            row.applied_definition_kind = appliedKind
            if appliedKind == 'group' then
                local normalized = GroupDefinitions.normalize(appliedCopy)
                if normalized then row.group_definition = normalized end
            end
        end
        existingByKey[row.definition_key] = row
    end

    for _, item in ipairs(plan) do
        local existing = existingByKey[item.key]
        item.existing = existing
        if not existing then
            item.change = 'create'
            item.version = 1
        elseif existing.definition_digest == item.digest
            and tonumber(existing.schema_version) == request.schema_version then
            local hasTarget = item.kind ~= 'group' or existing.target_group_id ~= nil
            item.change = existing.state == 'applied' and hasTarget
                and 'unchanged' or 'restore'
            item.version = tonumber(existing.version) + (item.change == 'restore' and 1 or 0)
            item.publicId = existing.public_id
        elseif tonumber(existing.schema_version) == nil
            or request.schema_version <= tonumber(existing.schema_version) then
            return rejected('CONCURRENT_MODIFICATION',
                'Changed static definitions must advance schema_version.', true, {
                    key = item.key,
                    current_schema_version = tonumber(existing.schema_version),
                    requested_schema_version = request.schema_version
                })
        else
            item.change = 'update'
            item.version = tonumber(existing.version) + 1
            item.publicId = existing.public_id
        end
        item.previousGroup = existing and existing.group_definition or nil
    end

    local orderedGroups, orderError = GroupDefinitions.ordered(plan, byKey)
    if not orderedGroups then return nil, orderError end
    for _, item in ipairs(orderedGroups) do
        if item.existing and item.existing.applied_definition_kind ~= nil
            and item.existing.applied_definition_kind ~= 'group' then
            return rejected('CONCURRENT_MODIFICATION',
                'Changing a static definition into a group requires an explicit migration.', true,
                { key = item.key })
        end
        GroupDefinitions.inspect(tx, item, runtime, request.dry_run)
    end
    for _, item in ipairs(plan) do
        if item.existing and item.existing.applied_definition_kind == 'group'
            and item.kind ~= 'group' then
            return rejected('CONCURRENT_MODIFICATION',
                'Changing a static group into another definition kind requires an explicit migration.', true,
                { key = item.key })
        end
    end
    for _, item in ipairs(orderedGroups) do
        local parent = item.group.parent_key and byKey[item.group.parent_key] or nil
        item.parentItem = parent
        if parent and parent.groupState and #parent.groupState.issues > 0 then
            item.groupState.issues[#item.groupState.issues + 1] = {
                code = 'PARENT_DEFINITION_BLOCKED', targetKind = 'definition', targetRef = '',
                details = { parent_key = parent.key }
            }
        elseif parent then
            local parentTarget = parent.existing and tonumber(parent.existing.target_group_id) or nil
            local currentParent = item.groupState.live
                and tonumber(item.groupState.live.parent_group_id) or nil
            if parentTarget == nil or parentTarget ~= currentParent then
                item.groupState.needsWrite = true
            end
        elseif item.groupState.live and item.groupState.live.parent_group_id ~= nil then
            item.groupState.needsWrite = true
        end
        if item.change == 'unchanged' and item.groupState.needsWrite then
            item.change = 'restore'
            item.version = tonumber(item.existing.version) + 1
        end
    end

    local resultItems, resultByKey = {}, {}
    for _, item in ipairs(plan) do
        local hasIssues = item.groupState and #item.groupState.issues > 0
        local result = {
            key = item.key,
            kind = item.kind,
            change = item.change,
            state = hasIssues and 'blocked'
                or request.dry_run and 'planned'
                or 'applied',
            schema_version = request.schema_version,
            version = item.version
        }
        if item.groupState then result.issue_count = #item.groupState.issues end
        resultByKey[item.key] = result
        resultItems[#resultItems + 1] = result
    end
    local truncated = false
    for _, existing in ipairs(existingRows) do
        if not byKey[existing.definition_key] then
            if #resultItems < 100 then
                resultItems[#resultItems + 1] = {
                    key = existing.definition_key,
                    kind = existing.definition_kind or 'unknown',
                    change = 'missing_from_request',
                    state = 'blocked',
                    schema_version = tonumber(existing.schema_version),
                    version = tonumber(existing.version)
                        + (not request.dry_run and existing.state ~= 'blocked' and 1 or 0)
                }
            else
                truncated = true
            end
        end
    end
    if request.dry_run then
        return { items = resultItems, truncated = truncated }, nil, {}
    end

    for _, item in ipairs(plan) do
        if item.change == 'create' then
            local id, idError = publicId(runtime, 'group_definition')
            if not id then return nil, idError end
            item.publicId = id
        end
    end
    local effects = {}
    local function persistIssue(item, issueItem)
        local detailsJson, detailsError = canonical(runtime, issueItem.details or {})
        if not detailsJson then return nil, detailsError end
        local issueId, issueIdError = publicId(runtime, 'group_def_issue')
        if not issueId then return nil, issueIdError end
        tx.query([[INSERT INTO synex_group_definition_issues
            (public_id, definition_set_id, issue_code, target_kind, target_ref,
             details_json, state, version)
            VALUES (?, ?, ?, ?, ?, ?, 'open', 1)
            ON DUPLICATE KEY UPDATE details_json = VALUES(details_json),
                version = version + 1]], {
            issueId, item.definitionSetId, issueItem.code,
            issueItem.targetKind or 'definition', issueItem.targetRef or '', detailsJson
        })
        return true, nil
    end
    local function persistDefinition(item, targetGroupId, state, applied)
        if not item.existing then
            item.definitionSetId = tx.insert([[INSERT INTO synex_group_definition_sets
                (public_id, owner_resource, definition_key, target_group_id,
                 schema_version, definition_json, definition_digest, applied_digest,
                 applied_definition_json, state, drift_detected_at, last_applied_at, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    CASE WHEN ? = 'applied' THEN NULL ELSE CURRENT_TIMESTAMP(6) END,
                    CASE WHEN ? = 'applied' THEN CURRENT_TIMESTAMP(6) ELSE NULL END, 1)]], {
                item.publicId, owner, item.key, targetGroupId,
                request.schema_version, item.encoded, item.digest,
                applied and item.digest or nil, applied and item.encoded or nil,
                state, state, state
            })
            item.version = 1
            return true, nil
        end
        local existing = item.existing
        local changed = tx.affected([[UPDATE synex_group_definition_sets
            SET target_group_id = COALESCE(?, target_group_id), schema_version = ?,
                definition_json = ?, definition_digest = ?,
                applied_digest = CASE WHEN ? = 'applied' THEN ? ELSE applied_digest END,
                applied_definition_json = CASE WHEN ? = 'applied' THEN ?
                    ELSE applied_definition_json END,
                state = ?,
                drift_detected_at = CASE WHEN ? = 'applied' THEN NULL
                    ELSE CURRENT_TIMESTAMP(6) END,
                last_applied_at = CASE WHEN ? = 'applied' THEN CURRENT_TIMESTAMP(6)
                    ELSE last_applied_at END,
                version = version + 1
            WHERE id = ? AND version = ?]], {
            targetGroupId, request.schema_version, item.encoded, item.digest,
            state, item.digest, state, item.encoded, state, state, state,
            existing.id, existing.version
        })
        if changed ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A static definition changed while it was being synchronized.', true)
        end
        item.definitionSetId = existing.id
        item.version = tonumber(existing.version) + 1
        return true, nil
    end
    local function recordAppliedMigration(item, summary)
        local migrationId, migrationError = publicId(runtime, 'group_def_migration')
        if not migrationId then return nil, migrationError end
        local planJson, planError = canonical(runtime, summary)
        if not planJson then return nil, planError end
        tx.query([[INSERT INTO synex_group_definition_migrations
            (public_id, definition_set_id, from_schema_version,
             to_schema_version, from_digest, to_digest, plan_json,
             state, owner_ref, locked_until, error_code, applied_at, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'applied', NULL, NULL, NULL,
                CURRENT_TIMESTAMP(6), 1)]], {
            migrationId, item.definitionSetId, item.existing.schema_version,
            request.schema_version, item.existing.definition_digest,
            item.digest, planJson
        })
        return true, nil
    end
    local function markBlockedMigrationApplied(item, summary)
        local planJson, planError = canonical(runtime, summary)
        if not planJson then return nil, planError end
        if tx.affected([[UPDATE synex_group_definition_migrations
            SET plan_json = ?, state = 'applied', owner_ref = NULL,
                locked_until = NULL, error_code = NULL,
                applied_at = CURRENT_TIMESTAMP(6), version = version + 1
            WHERE definition_set_id = ? AND to_schema_version = ?
                AND to_digest = ? AND state = 'blocked']], {
            planJson, item.definitionSetId, request.schema_version, item.digest
        }) ~= 1 then
            return rejected('DATABASE_RESULT_INVALID',
                'The blocked static definition migration could not be finalized.', true)
        end
        return true, nil
    end

    for _, item in ipairs(orderedGroups) do
        local state = item.groupState
        local parent = item.parentItem
        if #state.issues > 0 then
            item.blocked = true
            local storedState = item.existing and item.existing.applied_digest ~= nil
                and item.existing.applied_digest ~= item.digest and 'drifted' or 'blocked'
            local persisted, persistError = persistDefinition(item,
                item.existing and item.existing.target_group_id or nil, storedState, false)
            if not persisted then return nil, persistError end
            for _, issueItem in ipairs(state.issues) do
                local issueStored, issueError = persistIssue(item, issueItem)
                if not issueStored then return nil, issueError end
            end
            if item.existing and item.change == 'update' then
                local migrationId, migrationError = publicId(runtime, 'group_def_migration')
                if not migrationId then return nil, migrationError end
                local migrationPlan, planError = canonical(runtime, {
                    change = 'blocked_definition_reconciliation',
                    issue_count = #state.issues,
                    first_issue = state.issues[1].code
                })
                if not migrationPlan then return nil, planError end
                tx.query([[INSERT INTO synex_group_definition_migrations
                    (public_id, definition_set_id, from_schema_version,
                     to_schema_version, from_digest, to_digest, plan_json,
                     state, owner_ref, locked_until, error_code, applied_at, version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'blocked', NULL, NULL, ?, NULL, 1)
                    ON DUPLICATE KEY UPDATE plan_json = VALUES(plan_json),
                        state = 'blocked', owner_ref = NULL, locked_until = NULL,
                        error_code = VALUES(error_code), applied_at = NULL,
                        version = version + 1]], {
                    migrationId, item.definitionSetId, item.existing.schema_version,
                    request.schema_version, item.existing.definition_digest,
                    item.digest, migrationPlan, state.issues[1].code
                })
            end
            resultByKey[item.key].state = storedState
            resultByKey[item.key].version = item.version
            resultByKey[item.key].issue_count = #state.issues
        else
            local reconciled
            if state.mode == 'create' or state.needsWrite then
                local reconcileError
                reconciled, reconcileError = GroupDefinitions.reconcile(
                    tx, item, runtime, parent)
                if not reconciled then return nil, reconcileError end
                effects[#effects + 1] = reconciled.effect
            else
                item.targetGroupId = tonumber(state.live.id)
                item.targetGroupPublicId = state.live.public_id
                reconciled = {
                    targetGroupId = item.targetGroupId,
                    targetGroupPublicId = item.targetGroupPublicId,
                    summary = { group_id = item.targetGroupPublicId, unchanged = true }
                }
            end
            if item.change == 'unchanged' then
                item.definitionSetId = item.existing.id
                item.version = tonumber(item.existing.version)
            else
                local persisted, persistError = persistDefinition(
                    item, reconciled.targetGroupId, 'applied', true)
                if not persisted then return nil, persistError end
                if item.existing then
                    tx.query([[UPDATE synex_group_definition_issues
                        SET state = 'resolved', resolved_by_ref = NULL,
                            resolution_reason_code = 'static_definition_reconciled',
                            resolved_at = CURRENT_TIMESTAMP(6), version = version + 1
                        WHERE definition_set_id = ? AND state = 'open']],
                        { item.definitionSetId })
                end
            end
            resultByKey[item.key].state = 'applied'
            resultByKey[item.key].version = item.version
            resultByKey[item.key].group_id = reconciled.targetGroupPublicId
            if item.change == 'update' then
                local recorded, recordError = recordAppliedMigration(item, reconciled.summary)
                if not recorded then return nil, recordError end
            elseif item.change == 'restore' and item.existing.applied_digest ~= nil
                and item.existing.applied_digest ~= item.digest then
                local recorded, recordError = markBlockedMigrationApplied(
                    item, reconciled.summary)
                if not recorded then return nil, recordError end
            end
        end
    end

    for _, item in ipairs(plan) do
        if item.kind ~= 'group' then
            if item.change ~= 'unchanged' then
                local persisted, persistError = persistDefinition(item, nil, 'applied', true)
                if not persisted then return nil, persistError end
            else
                item.definitionSetId = item.existing.id
                item.version = tonumber(item.existing.version)
            end
            if item.change == 'update' then
                local recorded, recordError = recordAppliedMigration(item, {
                    change = 'catalog_definition_replaced', kind = item.kind
                })
                if not recorded then return nil, recordError end
            end
            if item.existing and item.change ~= 'unchanged' then
                tx.query([[UPDATE synex_group_definition_issues
                    SET state = 'resolved', resolved_by_ref = NULL,
                        resolution_reason_code = 'static_definition_reconciled',
                        resolved_at = CURRENT_TIMESTAMP(6), version = version + 1
                    WHERE definition_set_id = ? AND state = 'open']], { item.definitionSetId })
            end
            resultByKey[item.key].version = item.version
        end
    end
    for _, existing in ipairs(existingRows) do
        if not byKey[existing.definition_key] then
            if existing.state ~= 'blocked' then
                if tx.affected([[UPDATE synex_group_definition_sets
                    SET state = 'blocked', drift_detected_at = CURRENT_TIMESTAMP(6),
                        version = version + 1 WHERE id = ? AND version = ?]],
                    { existing.id, existing.version }) ~= 1 then
                    return rejected('CONCURRENT_MODIFICATION',
                        'A missing static definition changed during synchronization.', true)
                end
            end
            local issueId, issueIdError = publicId(runtime, 'group_def_issue')
            if not issueId then return nil, issueIdError end
            tx.query([[INSERT INTO synex_group_definition_issues
                (public_id, definition_set_id, issue_code, target_kind, target_ref,
                 details_json, state, version)
                VALUES (?, ?, 'DEFINITION_MISSING', 'definition', '', '{}', 'open', 1)
                ON DUPLICATE KEY UPDATE version = version + 1]], { issueId, existing.id })
        end
    end

    return { items = resultItems, truncated = truncated }, nil, effects
end

return handlers
end
