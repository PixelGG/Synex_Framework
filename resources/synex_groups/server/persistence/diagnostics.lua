return function(Foundation)
local handlers = { read = {}, execute = {} }

local function decodeOptional(runtime, value)
    if value == nil then return nil, nil end
    local decodedOk, decoded = pcall(runtime.jsonDecode, value)
    if not decodedOk then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'A Groups history record contains invalid JSON.')
    end
    local copiedOk, copied = pcall(Foundation.copyPlain, decoded)
    if not copiedOk then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'A Groups history record exceeds the supported JSON bounds.')
    end
    return copied, nil
end

function handlers.read.history_list(tx, request, runtime)
    local _, authorizationError = runtime.authorize(tx, request.group_id,
        request.actor_character_id, 'synex.groups.history.read', 'group')
    if authorizationError then return nil, authorizationError end

    local cursorId
    if request.cursor ~= nil then
        local cursor = tx.one([[SELECT id FROM synex_group_domain_history
            WHERE event_id = ? AND group_public_id = ?]], {
            request.cursor, request.group_id
        })
        if not cursor then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'The Groups history cursor is not valid for this group.')
        end
        cursorId = cursor.id
    end

    local limit = math.max(1, math.min(tonumber(request.limit) or 50, 100))
    local conditions = { 'group_public_id = ?' }
    local parameters = { request.group_id }
    if request.entity_type ~= nil then
        conditions[#conditions + 1] = 'aggregate_type = ?'
        parameters[#parameters + 1] = request.entity_type
    end
    if request.entity_id ~= nil then
        conditions[#conditions + 1] = 'aggregate_id = ?'
        parameters[#parameters + 1] = request.entity_id
    end
    if cursorId ~= nil then
        conditions[#conditions + 1] = 'id < ?'
        parameters[#parameters + 1] = cursorId
    end
    parameters[#parameters + 1] = limit + 1
    local rows = tx.many([[SELECT event_id, aggregate_type, aggregate_id,
            aggregate_version, event_type, source_resource, actor_kind, actor_ref,
            reason_code, correlation_id, before_json, after_json,
            DATE_FORMAT(occurred_at, '%Y-%m-%dT%H:%i:%s.%fZ') AS occurred_at
        FROM synex_group_domain_history
        WHERE ]] .. table.concat(conditions, ' AND ') .. [[
        ORDER BY id DESC LIMIT ?]], parameters)

    local truncated = #rows > limit
    if truncated then rows[#rows] = nil end
    local items = {}
    for _, row in ipairs(rows) do
        local before, beforeError = decodeOptional(runtime, row.before_json)
        if beforeError then return nil, beforeError end
        local after, afterError = decodeOptional(runtime, row.after_json)
        if afterError then return nil, afterError end
        items[#items + 1] = {
            event_id = row.event_id,
            entity_type = row.aggregate_type,
            entity_id = row.aggregate_id,
            version = tonumber(row.aggregate_version),
            event_type = row.event_type,
            source_resource = row.source_resource,
            actor = { kind = row.actor_kind, ref = row.actor_ref },
            reason = row.reason_code,
            trace_id = row.correlation_id,
            before = before,
            after = after,
            occurred_at = row.occurred_at
        }
    end
    return {
        items = items,
        next_cursor = truncated and items[#items].event_id or nil,
        truncated = truncated
    }, nil
end

local doctorChecks = {
    {
        key = 'orphan_membership', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_memberships AS membership
            LEFT JOIN synex_groups AS group_record ON group_record.id = membership.group_id
            LEFT JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = membership.id
            WHERE group_record.id IS NULL OR profile.membership_id IS NULL]]
    },
    {
        key = 'missing_grade', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_membership_profiles AS profile
            LEFT JOIN synex_group_membership_grades AS assigned
                ON assigned.membership_id = profile.membership_id
            LEFT JOIN synex_group_grades AS grade ON grade.id = assigned.grade_id
            WHERE profile.lifecycle_state = 'ACTIVE'
                AND (assigned.membership_id IS NULL OR grade.id IS NULL OR grade.status <> 'active')]]
    },
    {
        key = 'missing_role', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_membership_roles AS assigned
            LEFT JOIN synex_group_roles AS role ON role.id = assigned.role_id
            WHERE assigned.status = 'active'
                AND (role.id IS NULL OR role.status <> 'active')]]
    },
    {
        key = 'duplicate_active_membership', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count FROM (
            SELECT profile.group_id, profile.character_id
            FROM synex_group_membership_profiles AS profile
            WHERE profile.lifecycle_state = 'ACTIVE'
            GROUP BY profile.group_id, profile.character_id HAVING COUNT(*) > 1
        ) AS duplicates]]
    },
    {
        key = 'expired_role_still_active', severity = 'WARN',
        sql = [[SELECT COUNT(*) AS count FROM synex_group_membership_roles
            WHERE status = 'active' AND valid_until IS NOT NULL
                AND valid_until <= CURRENT_TIMESTAMP(6)]]
    },
    {
        key = 'expired_delegation_still_active', severity = 'WARN',
        sql = [[SELECT COUNT(*) AS count FROM synex_group_delegations
            WHERE status = 'active' AND valid_until <= CURRENT_TIMESTAMP(6)]]
    },
    {
        key = 'broken_parent', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_hierarchy_edges AS edge
            LEFT JOIN synex_groups AS child_record ON child_record.id = edge.child_group_id
            LEFT JOIN synex_groups AS parent_record ON parent_record.id = edge.parent_group_id
            WHERE child_record.id IS NULL OR parent_record.id IS NULL
                OR edge.child_group_id = edge.parent_group_id]]
    },
    {
        key = 'hierarchy_cycle', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_hierarchy_closure AS forward_path
            INNER JOIN synex_group_hierarchy_closure AS reverse_path
                ON reverse_path.ancestor_group_id = forward_path.descendant_group_id
                AND reverse_path.descendant_group_id = forward_path.ancestor_group_id
            WHERE forward_path.depth > 0 AND reverse_path.depth > 0
                AND forward_path.ancestor_group_id < forward_path.descendant_group_id]]
    },
    {
        key = 'reporting_cycle', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_reporting_closure AS forward_path
            INNER JOIN synex_group_reporting_closure AS reverse_path
                ON reverse_path.manager_membership_id = forward_path.report_membership_id
                AND reverse_path.report_membership_id = forward_path.manager_membership_id
            WHERE forward_path.depth > 0 AND reverse_path.depth > 0
                AND forward_path.manager_membership_id < forward_path.report_membership_id]]
    },
    {
        key = 'dangling_relationship', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_relationships AS relationship
            LEFT JOIN synex_group_relation_types AS relation_type
                ON relation_type.id = relationship.relation_type_id
            LEFT JOIN synex_groups AS source_group
                ON source_group.id = relationship.source_group_id
            LEFT JOIN synex_groups AS target_group
                ON target_group.id = relationship.target_group_id
            WHERE relationship.status = 'active'
                AND (relation_type.id IS NULL OR relation_type.status <> 'active'
                    OR source_group.id IS NULL OR source_group.status <> 'active'
                    OR target_group.id IS NULL OR target_group.status <> 'active')]]
    },
    {
        key = 'invalid_capability', severity = 'FAIL',
        sql = [[SELECT
            (SELECT COUNT(*) FROM synex_group_grade_capabilities
                WHERE capability_pattern NOT REGEXP '^[a-z][a-z0-9._*-]{0,127}$'
                    OR effect NOT IN ('allow', 'deny')
                    OR delegable NOT IN (0, 1) OR (effect = 'deny' AND delegable <> 0))
            + (SELECT COUNT(*) FROM synex_group_role_capabilities
                WHERE capability_pattern NOT REGEXP '^[a-z][a-z0-9._*-]{0,127}$'
                    OR effect NOT IN ('allow', 'deny')
                    OR delegable NOT IN (0, 1) OR (effect = 'deny' AND delegable <> 0))
            + (SELECT COUNT(*) FROM synex_group_default_capabilities
                WHERE capability_pattern NOT REGEXP '^[a-z][a-z0-9._*-]{0,95}$'
                    OR effect NOT IN ('allow', 'deny')
                    OR delegable NOT IN (0, 1) OR (effect = 'deny' AND delegable <> 0))
            + (SELECT COUNT(*) FROM synex_group_membership_capabilities
                WHERE capability_pattern NOT REGEXP '^[a-z][a-z0-9._*-]{0,95}$'
                    OR effect NOT IN ('allow', 'deny')
                    OR delegable NOT IN (0, 1) OR (effect = 'deny' AND delegable <> 0)) AS count]]
    },
    {
        key = 'invalid_scope', severity = 'FAIL',
        sql = [[SELECT
            (SELECT COUNT(*) FROM synex_group_grade_capability_scopes
                WHERE scope_kind NOT IN ('global', 'group', 'relationship', 'assignment', 'custom')
                    OR (scope_kind IN ('global', 'group') AND scope_ref <> '')
                    OR (scope_kind NOT IN ('global', 'group') AND scope_ref = ''))
            + (SELECT COUNT(*) FROM synex_group_role_capabilities
                WHERE scope_kind NOT IN ('global', 'group', 'relationship', 'assignment', 'custom')
                    OR (scope_kind IN ('global', 'group') AND scope_ref <> '')
                    OR (scope_kind NOT IN ('global', 'group') AND scope_ref = ''))
            + (SELECT COUNT(*) FROM synex_group_default_capabilities
                WHERE scope_kind NOT IN ('group', 'subtree', 'custom')
                    OR (scope_kind = 'group' AND scope_ref <> '')
                    OR (scope_kind <> 'group' AND scope_ref = ''))
            + (SELECT COUNT(*) FROM synex_group_membership_capabilities
                WHERE scope_kind NOT IN ('group', 'subtree', 'custom')
                    OR (scope_kind = 'group' AND scope_ref <> '')
                    OR (scope_kind <> 'group' AND scope_ref = '')) AS count]]
    },
    {
        key = 'policy_conflict', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_policy_rules AS allow_rule
            INNER JOIN synex_group_policy_rules AS deny_rule
                ON deny_rule.policy_id = allow_rule.policy_id
                AND deny_rule.action_pattern = allow_rule.action_pattern
                AND deny_rule.priority = allow_rule.priority
                AND deny_rule.subject_kind = allow_rule.subject_kind
                AND deny_rule.scope_kind = allow_rule.scope_kind
                AND deny_rule.scope_ref = allow_rule.scope_ref
                AND deny_rule.effect = 'deny'
            WHERE allow_rule.effect = 'allow']]
    },
    {
        key = 'definition_drift', severity = 'WARN',
        sql = [[SELECT COUNT(*) AS count FROM synex_group_definition_sets
            WHERE state = 'drifted'
                OR (applied_digest IS NOT NULL AND applied_digest <> definition_digest)]]
    },
    {
        key = 'active_duty_without_active_membership', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_duty_sessions AS duty
            LEFT JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = duty.membership_id
            WHERE duty.status = 'open'
                AND (profile.membership_id IS NULL OR profile.lifecycle_state <> 'ACTIVE')]]
    },
    {
        key = 'assignment_references_inactive_membership', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_assignment_members AS assignment_member
            INNER JOIN synex_group_assignments AS assignment
                ON assignment.id = assignment_member.assignment_id
            LEFT JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = assignment_member.membership_id
            WHERE assignment.status = 'active' AND assignment_member.status = 'active'
                AND (profile.membership_id IS NULL OR profile.lifecycle_state <> 'ACTIVE')]]
    },
    {
        key = 'active_member_on_inactive_assignment', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_assignment_members AS assignment_member
            INNER JOIN synex_group_assignments AS assignment
                ON assignment.id = assignment_member.assignment_id
            WHERE assignment_member.status = 'active'
                AND (assignment.status <> 'active'
                    OR assignment.valid_from > CURRENT_TIMESTAMP(6)
                    OR (assignment.valid_until IS NOT NULL
                        AND assignment.valid_until <= CURRENT_TIMESTAMP(6)))]]
    },
    {
        key = 'open_duty_on_inactive_assignment', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count
            FROM synex_group_duty_sessions AS duty
            LEFT JOIN synex_group_assignments AS assignment
                ON assignment.id = duty.assignment_id
            WHERE duty.status = 'open' AND duty.assignment_id IS NOT NULL
                AND (assignment.id IS NULL OR assignment.status <> 'active'
                    OR assignment.valid_from > CURRENT_TIMESTAMP(6)
                    OR (assignment.valid_until IS NOT NULL
                        AND assignment.valid_until <= CURRENT_TIMESTAMP(6)))]]
    },
    {
        key = 'slug_reservation_mismatch', severity = 'FAIL',
        sql = [[SELECT COUNT(*) AS count FROM (
            SELECT group_record.public_id AS owner_public_id
            FROM synex_groups AS group_record
            LEFT JOIN synex_group_slug_reservations AS reservation
                ON reservation.slug = group_record.group_key
                AND reservation.owner_kind = 'group'
                AND reservation.owner_public_id = group_record.public_id
            WHERE reservation.slug IS NULL
            UNION ALL
            SELECT request.public_id AS owner_public_id
            FROM synex_group_creation_requests AS request
            LEFT JOIN synex_group_slug_reservations AS reservation
                ON reservation.slug = request.requested_slug
                AND reservation.owner_kind = 'creation_request'
                AND reservation.owner_public_id = request.public_id
            WHERE request.status IN ('pending', 'approved')
                AND reservation.slug IS NULL
            UNION ALL
            SELECT reservation.owner_public_id
            FROM synex_group_slug_reservations AS reservation
            LEFT JOIN synex_groups AS group_record
                ON reservation.owner_kind = 'group'
                AND group_record.public_id = reservation.owner_public_id
                AND group_record.group_key = reservation.slug
            LEFT JOIN synex_group_creation_requests AS request
                ON reservation.owner_kind = 'creation_request'
                AND request.public_id = reservation.owner_public_id
                AND request.requested_slug = reservation.slug
                AND request.status IN ('pending', 'approved')
            WHERE (reservation.owner_kind = 'group' AND group_record.id IS NULL)
                OR (reservation.owner_kind = 'creation_request' AND request.id IS NULL)
        ) AS reservation_issues]]
    },
    {
        key = 'dead_audit_delivery', severity = 'WARN',
        sql = [[SELECT COUNT(*) AS count FROM synex_group_audit_delivery
            WHERE state = 'dead']]
    }
}

function handlers.read.doctor(tx, _, runtime)
    local checks, overall = {}, 'PASS'
    for _, definition in ipairs(doctorChecks) do
        local row = tx.one(definition.sql)
        local count = tonumber(row and row.count)
        if count == nil or count < 0 then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'A Groups doctor check returned an invalid count.', true)
        end
        local status = count == 0 and 'PASS' or definition.severity
        if status == 'FAIL' then overall = 'FAIL'
        elseif status == 'WARN' and overall == 'PASS' then overall = 'WARN' end
        checks[#checks + 1] = { key = definition.key, status = status, count = count }
    end

    local registrySnapshot = {}
    for name, registry in pairs(runtime.registries) do
        registrySnapshot[name] = registry:stats()
    end
    local cacheSnapshot = runtime.cache:snapshot()
    cacheSnapshot.definitions = runtime.definitionCache:snapshot()
    return {
        status = overall,
        checks = checks,
        cache = cacheSnapshot,
        registries = registrySnapshot,
        runtimeIndex = runtime.runtimeIndex:snapshot()
    }, nil
end

return handlers
end
