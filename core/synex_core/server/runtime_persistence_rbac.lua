local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.runtimePersistenceRbac = function(context)
    local foundation = context.foundation
    local database = context.database
    local platform = context.platform
    local maintenanceBatchMaximum = context.maintenanceBatchMaximum
    local affectedRows = context.affectedRows

    local rbac = {}
    local roleSnapshotMaximum = 16384

    local function encodeAudit(value)
        if value == nil then return nil, nil end
        local ok, encoded = pcall(platform.jsonEncode, value)
        if not ok or type(encoded) ~= 'string' or #encoded > 16384 then
            return nil, foundation.error('AUDIT_ENCODING_FAILED', 'RBAC audit data could not be encoded.')
        end
        return encoded, nil
    end

    local function auditParameters(action, targetType, targetId, context, before, after)
        local beforeJson, beforeError = encodeAudit(before)
        if beforeError then return nil, beforeError end
        local afterJson, afterError = encodeAudit(after)
        if afterError then return nil, afterError end
        local contextJson, contextError = encodeAudit({ reason = context.reason })
        if contextError then return nil, contextError end
        return {
            foundation.nextId('audit'), context.traceId, context.actorType or 'resource', context.actor,
            action, targetType, targetId, beforeJson, afterJson, contextJson
        }, nil
    end

    local function normalizedPermissionRows(rows)
        local permissions = {}
        for _, row in ipairs(rows or {}) do
            permissions[#permissions + 1] = { permission = row.permission_key, effect = row.effect }
        end
        return permissions
    end

    local function policyRevision(value)
        local revision = tonumber(value)
        if not revision or math.type(revision) ~= 'integer' or revision < 1 then
            return nil, foundation.error('RBAC_POLICY_REVISION_INVALID',
                'The persistent RBAC policy revision is invalid.')
        end
        return revision, nil
    end

    local function loadRoleRows(query)
        local rows = query([[SELECT `role`.`role_name`, `role`.`version`,
                `permission`.`permission_key`, `permission`.`effect`
            FROM `synex_rbac_roles` AS `role`
            LEFT JOIN `synex_rbac_role_permissions` AS `permission`
                ON `permission`.`role_name` = `role`.`role_name`
            ORDER BY `role`.`role_name`, `permission`.`permission_key`, `permission`.`effect`
            LIMIT ?]], { roleSnapshotMaximum + 1 })
        if type(rows) ~= 'table' or #rows > roleSnapshotMaximum then
            return nil, foundation.error('RBAC_TOO_LARGE',
                'Persistent RBAC role data exceeds the safe snapshot limit.')
        end
        local roleVersions, emptyRoles, seenPermissions = {}, {}, {}
        for _, row in ipairs(rows) do
            local name = type(row) == 'table' and row.role_name or nil
            if type(name) ~= 'string' or #name < 1 or #name > 64
                or not name:match('^[a-z][a-z0-9%._%-]*$')
                or name:match('[%._%-]$') or name:match('[%._%-][%._%-]') then
                return nil, foundation.error('RBAC_DATA_INVALID',
                    'The persistent RBAC snapshot contains an invalid role.')
            end
            local version = tonumber(row.version)
            if not version or math.type(version) ~= 'integer' or version < 1
                or (roleVersions[name] and roleVersions[name] ~= version) then
                return nil, foundation.error('RBAC_DATA_INVALID',
                    'The persistent RBAC snapshot contains an invalid role version.')
            end
            roleVersions[name] = version
            local permission = row.permission_key
            if permission == nil then
                if row.effect ~= nil or emptyRoles[name] or seenPermissions[name] then
                    return nil, foundation.error('RBAC_DATA_INVALID',
                        'The persistent RBAC snapshot contains an invalid empty role.')
                end
                emptyRoles[name] = true
            else
                local wildcard = type(permission) == 'string' and permission:find('*', 1, true) or nil
                local base = type(permission) == 'string' and permission or ''
                if wildcard then base = permission:sub(1, -3) end
                if type(permission) ~= 'string' or #permission < 1 or #permission > 128
                    or not permission:match('^[a-z][a-z0-9%._%-%*]*$')
                    or (wildcard and (permission:sub(-2) ~= '.*' or wildcard ~= #permission))
                    or not base:match('^[a-z][a-z0-9%._%-]*$')
                    or base:match('[%._%-]$') or base:match('[%._%-][%._%-]')
                    or (row.effect ~= 'allow' and row.effect ~= 'deny') or emptyRoles[name] then
                    return nil, foundation.error('RBAC_DATA_INVALID',
                        'The persistent RBAC snapshot contains an invalid permission.')
                end
                seenPermissions[name] = seenPermissions[name] or {}
                local permissionKey = row.effect .. ':' .. permission
                if seenPermissions[name][permissionKey] then
                    return nil, foundation.error('RBAC_DATA_INVALID',
                        'The persistent RBAC snapshot contains a duplicate permission.')
                end
                seenPermissions[name][permissionKey] = true
            end
        end
        return rows, nil
    end

    function rbac:loadPolicyRevision()
        local revision, revisionError = database:scalar([[SELECT `revision`
            FROM `synex_rbac_policy_revisions` WHERE `singleton_id` = ?]], { 1 })
        if revisionError then return nil, revisionError end
        return policyRevision(revision)
    end

    function rbac:loadRoleSnapshot()
        local snapshot, snapshotError
        local committed, err = database:withTransaction(function(query)
            local revisionRows = query([[SELECT `revision` FROM `synex_rbac_policy_revisions`
                WHERE `singleton_id` = ? FOR UPDATE]], { 1 })
            if type(revisionRows) ~= 'table' or #revisionRows ~= 1
                or type(revisionRows[1]) ~= 'table' then
                snapshotError = foundation.error('RBAC_POLICY_REVISION_INVALID',
                    'The persistent RBAC policy revision singleton is unavailable.')
                return false
            end
            local revision, revisionError = policyRevision(revisionRows[1].revision)
            if not revision then snapshotError = revisionError return false end
            local rows, roleError = loadRoleRows(query)
            if not rows then snapshotError = roleError return false end
            snapshot = { revision = revision, rows = rows }
            return true
        end)
        if snapshotError then return nil, snapshotError end
        if not committed then return nil, err end
        return snapshot, nil
    end

    function rbac:defineRole(name, permissions, context)
        local auditError, domainError, snapshot
        local committed, err = database:withTransaction(function(query)
            local revisionRows = query([[SELECT `revision` FROM `synex_rbac_policy_revisions`
                WHERE `singleton_id` = ? FOR UPDATE]], { 1 })
            if type(revisionRows) ~= 'table' or #revisionRows ~= 1
                or type(revisionRows[1]) ~= 'table' then
                domainError = foundation.error('RBAC_POLICY_REVISION_INVALID',
                    'The persistent RBAC policy revision singleton is unavailable.')
                return false
            end
            local currentRevision, revisionError = policyRevision(revisionRows[1].revision)
            if not currentRevision then domainError = revisionError return false end
            if currentRevision >= math.maxinteger then
                domainError = foundation.error('RBAC_POLICY_REVISION_EXHAUSTED',
                    'The persistent RBAC policy revision cannot advance safely.')
                return false
            end
            local roleRows = query(
                'SELECT `version` FROM `synex_rbac_roles` WHERE `role_name` = ? FOR UPDATE', { name })
            if type(roleRows) ~= 'table' or #roleRows > 1
                or (roleRows[1] ~= nil and type(roleRows[1]) ~= 'table') then
                domainError = foundation.error('RBAC_DATA_INVALID',
                    'The persistent RBAC role record is invalid.')
                return false
            end
            local currentPermissions = {}
            if roleRows[1] then
                currentPermissions = query([[SELECT `permission_key`, `effect`
                    FROM `synex_rbac_role_permissions` WHERE `role_name` = ?
                    ORDER BY `permission_key`, `effect` LIMIT ?]], { name, 513 })
                if type(currentPermissions) ~= 'table' or #currentPermissions > 512 then
                    domainError = foundation.error('RBAC_DATA_INVALID',
                        'The persistent RBAC role permissions are invalid.')
                    return false
                end
            end
            local currentRoleVersion = roleRows[1] and tonumber(roleRows[1].version) or 0
            if (roleRows[1] and not tonumber(roleRows[1].version))
                or currentRoleVersion < 0 or math.type(currentRoleVersion) ~= 'integer'
                or currentRoleVersion >= math.maxinteger then
                domainError = foundation.error('RBAC_DATA_INVALID',
                    'The persistent RBAC role version is invalid.')
                return false
            end
            local before = roleRows[1] and {
                version = currentRoleVersion,
                permissions = normalizedPermissionRows(currentPermissions)
            } or nil
            local after = {
                version = currentRoleVersion + 1,
                permissions = foundation.copy(permissions)
            }
            local auditValues
            auditValues, auditError = auditParameters('rbac.role.define', 'rbac_role', name, context, before, after)
            if not auditValues then return false end
            query([[INSERT INTO `synex_rbac_roles` (`role_name`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { name })
            query('DELETE FROM `synex_rbac_role_permissions` WHERE `role_name` = ?', { name })
            for _, permission in ipairs(permissions) do
                query([[INSERT INTO `synex_rbac_role_permissions`
                    (`role_name`, `permission_key`, `effect`) VALUES (?, ?, ?)]],
                    { name, permission.permission, permission.effect })
            end
            local revisionUpdate = query([[UPDATE `synex_rbac_policy_revisions`
                SET `revision` = `revision` + 1 WHERE `singleton_id` = ? AND `revision` = ?]],
                { 1, currentRevision })
            if affectedRows(revisionUpdate) ~= 1 then
                domainError = foundation.error('RBAC_POLICY_REVISION_CONFLICT',
                    'The persistent RBAC policy revision did not advance atomically.', {
                        retryable = true
                    })
                return false
            end
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            local snapshotRows, snapshotError = loadRoleRows(query)
            if not snapshotRows then domainError = snapshotError return false end
            snapshot = {
                revision = currentRevision + 1,
                committedRevision = currentRevision + 1,
                rows = snapshotRows
            }
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return snapshot, nil
    end

    function rbac:assign(subject, role, context)
        local auditError
        local committed, err = database:withTransaction(function(query)
            local rows = query([[SELECT `assigned_by_ref`, `expires_at` FROM `synex_rbac_subject_roles`
                WHERE `subject_ref` = ? AND `role_name` = ? FOR UPDATE]], { subject, role }) or {}
            local before = rows[1] and {
                role = role, assigned = true, expiresAt = rows[1].expires_at and tostring(rows[1].expires_at) or nil
            } or { role = role, assigned = false }
            local after = { role = role, assigned = true, expiresAt = context.expiresAt }
            local auditValues
            auditValues, auditError = auditParameters(
                'rbac.assignment.assign', 'rbac_subject', subject, context, before, after)
            if not auditValues then return false end
            query([[INSERT INTO `synex_rbac_subject_roles`
                (`subject_ref`, `role_name`, `assigned_by_ref`, `expires_at`)
                VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE `assigned_by_ref` = VALUES(`assigned_by_ref`),
                    `assigned_at` = CURRENT_TIMESTAMP(6), `expires_at` = VALUES(`expires_at`)]],
                { subject, role, context.actor, context.expiresAt })
            query([[INSERT INTO `synex_rbac_subject_versions` (`subject_ref`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { subject })
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            return true
        end)
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return true, nil
    end

    function rbac:revoke(subject, role, context)
        local auditError, domainError
        local committed, err = database:withTransaction(function(query)
            local rows = query([[SELECT `assigned_by_ref`, `expires_at` FROM `synex_rbac_subject_roles`
                WHERE `subject_ref` = ? AND `role_name` = ? FOR UPDATE]], { subject, role }) or {}
            if not rows[1] then
                domainError = foundation.error('ROLE_ASSIGNMENT_NOT_FOUND', 'The role assignment does not exist.')
                return false
            end
            local before = {
                role = role, assigned = true, expiresAt = rows[1].expires_at and tostring(rows[1].expires_at) or nil
            }
            local auditValues
            auditValues, auditError = auditParameters('rbac.assignment.revoke', 'rbac_subject', subject,
                context, before, { role = role, assigned = false })
            if not auditValues then return false end
            query('DELETE FROM `synex_rbac_subject_roles` WHERE `subject_ref` = ? AND `role_name` = ?',
                { subject, role })
            query([[INSERT INTO `synex_rbac_subject_versions` (`subject_ref`, `version`)
                VALUES (?, 1) ON DUPLICATE KEY UPDATE `version` = `version` + 1]], { subject })
            query([[INSERT INTO `synex_audit_log`
                (`event_id`, `trace_id`, `actor_type`, `actor_id`, `action`, `target_type`, `target_id`,
                    `before_json`, `after_json`, `context_json`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], auditValues)
            return true
        end)
        if domainError then return nil, domainError end
        if auditError then return nil, auditError end
        if not committed then return nil, err end
        return true, nil
    end

    function rbac:loadSubjectVersion(subject)
        local version, versionError = database:scalar(
            'SELECT `version` FROM `synex_rbac_subject_versions` WHERE `subject_ref` = ?', { subject })
        if versionError then return nil, versionError end
        version = tonumber(version) or 0
        if math.type(version) ~= 'integer' or version < 0 or version >= math.maxinteger then
            return nil, foundation.error('RBAC_DATA_INVALID',
                'The persistent RBAC subject version is invalid.')
        end
        return version, nil
    end

    function rbac:loadSubject(subject)
        for attempt = 1, 2 do
            local versionBefore, beforeError = self:loadSubjectVersion(subject)
            if versionBefore == nil then return nil, beforeError end
            local observedAt = foundation.monotonicMs()
            local rows, roleError = database:query([[SELECT `role_name`,
                    CASE WHEN `expires_at` IS NULL THEN NULL ELSE
                        FLOOR(GREATEST(0, TIMESTAMPDIFF(MICROSECOND,
                            CURRENT_TIMESTAMP(6), `expires_at`)) / 1000) END AS `remaining_ms`
                FROM `synex_rbac_subject_roles`
                WHERE `subject_ref` = ?
                    AND (`expires_at` IS NULL OR `expires_at` > CURRENT_TIMESTAMP(6))
                ORDER BY `role_name` LIMIT 513]], { subject })
            if roleError then return nil, roleError end
            if type(rows) ~= 'table' or #rows > 512 then
                return nil, foundation.error('RBAC_DATA_INVALID',
                    'The persistent RBAC subject assignments exceed the safe bound.')
            end
            local versionAfter, afterError = self:loadSubjectVersion(subject)
            if versionAfter == nil then return nil, afterError end
            if versionAfter == versionBefore then
                local elapsed = math.max(0, foundation.monotonicMs() - observedAt)
                local roles, validForMs = {}, nil
                for _, row in ipairs(rows) do
                    if type(row) ~= 'table' or type(row.role_name) ~= 'string'
                        or #row.role_name < 1 or #row.role_name > 64 then
                        return nil, foundation.error('RBAC_DATA_INVALID',
                            'The persistent RBAC subject contains an invalid role.')
                    end
                    local stillActive = true
                    if row.remaining_ms ~= nil then
                        local remaining = tonumber(row.remaining_ms)
                        if not remaining or math.type(remaining) ~= 'integer' or remaining < 0 then
                            return nil, foundation.error('RBAC_DATA_INVALID',
                                'The persistent RBAC assignment expiry is invalid.')
                        end
                        remaining = math.max(0, remaining - elapsed)
                        validForMs = validForMs and math.min(validForMs, remaining) or remaining
                        stillActive = remaining > 0
                    end
                    if stillActive then roles[#roles + 1] = row.role_name end
                end
                return { version = versionAfter, roles = roles, validForMs = validForMs }, nil
            end
        end
        return nil, foundation.error('RBAC_SUBJECT_SNAPSHOT_STALE',
            'The persistent RBAC subject changed during its bounded snapshot.', {
                retryable = true
            })
    end

    function rbac:summary()
        local probeLimit = maintenanceBatchMaximum + 1
        local roleRows, roleError = database:query([[SELECT `role_name` FROM `synex_rbac_roles`
            ORDER BY `role_name` LIMIT ?]], { probeLimit })
        if roleError then return nil, roleError end
        local assignmentRows, assignmentError = database:query([[
            SELECT `active_assignment`.`subject_ref`, `active_assignment`.`role_name`
            FROM (
                (SELECT `subject_ref`, `role_name`, `expires_at`
                    FROM `synex_rbac_subject_roles`
                        FORCE INDEX (`idx_rbac_subject_roles_expiry`)
                    WHERE `expires_at` IS NULL
                    ORDER BY `expires_at`, `subject_ref` LIMIT ?)
                UNION ALL
                (SELECT `subject_ref`, `role_name`, `expires_at`
                    FROM `synex_rbac_subject_roles`
                        FORCE INDEX (`idx_rbac_subject_roles_expiry`)
                    WHERE `expires_at` > CURRENT_TIMESTAMP(6)
                    ORDER BY `expires_at`, `subject_ref` LIMIT ?)
            ) AS `active_assignment`
            ORDER BY `active_assignment`.`subject_ref`, `active_assignment`.`role_name`
            LIMIT ?]], { probeLimit, probeLimit, probeLimit })
        if assignmentError then return nil, assignmentError end
        if type(roleRows) ~= 'table' or type(assignmentRows) ~= 'table'
            or #roleRows > probeLimit or #assignmentRows > probeLimit then
            return nil, foundation.error('RBAC_SUMMARY_INVALID',
                'The bounded RBAC summary is invalid.', { retryable = true })
        end
        return {
            roles = math.min(#roleRows, maintenanceBatchMaximum),
            activeAssignments = math.min(#assignmentRows, maintenanceBatchMaximum),
            rolesTruncated = #roleRows > maintenanceBatchMaximum,
            activeAssignmentsTruncated = #assignmentRows > maintenanceBatchMaximum
        }, nil
    end

    return rbac
end
