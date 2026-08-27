return function(Foundation)
    local OPERATIONS = {
        'summary', 'health', 'list', 'inspect', 'search', 'findings', 'simulate'
    }
    local VIEWS = {
        { id = 'overview', label = 'Groups overview', operation = 'summary', presentation = 'key-value', order = 10,
            description = 'Bounded organization and membership totals.' },
        { id = 'health', label = 'Groups health', operation = 'health', presentation = 'key-value', order = 20,
            description = 'Read-only domain consistency checks.' },
        { id = 'groups', label = 'Groups', operation = 'list', presentation = 'table', order = 30,
            description = 'Cursor-based organization directory.' },
        { id = 'memberships', label = 'Memberships', operation = 'list', presentation = 'table', order = 40,
            description = 'Cursor-based memberships for an authorized actor.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'hierarchy', label = 'Hierarchy', operation = 'list', presentation = 'graph', order = 50,
            description = 'Bounded parent and child organization edges.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'roles', label = 'Roles', operation = 'list', presentation = 'table', order = 60,
            description = 'Cursor-based roles owned by one group.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'grades', label = 'Grades', operation = 'list', presentation = 'table', order = 70,
            description = 'Cursor-based grades owned by one group.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'capabilities', label = 'Capabilities', operation = 'list', presentation = 'table', order = 80,
            description = 'Bounded role and grade capability rules.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'duty', label = 'Duty', operation = 'list', presentation = 'timeline', order = 90,
            description = 'Cursor-based duty sessions for an authorized actor.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'assignments', label = 'Assignments', operation = 'list', presentation = 'table', order = 100,
            description = 'Cursor-based group assignments.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'delegations', label = 'Delegations', operation = 'list', presentation = 'table', order = 110,
            description = 'Cursor-based delegated capability metadata.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'relationships', label = 'Relationships', operation = 'list', presentation = 'graph', order = 120,
            description = 'Bounded organization relationship graph.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'policies', label = 'Policies', operation = 'list', presentation = 'table', order = 130,
            description = 'Cursor-based policy metadata without conditions.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'drift', label = 'Drift', operation = 'findings', presentation = 'findings', order = 140,
            description = 'Current definition, registry, cache, and runtime findings.' },
        { id = 'history', label = 'History', operation = 'list', presentation = 'timeline', order = 150,
            description = 'Cursor-based domain history.', input = { fields = {
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'group', label = 'Group inspector', operation = 'inspect', presentation = 'detail', order = 160,
            description = 'Inspect one organization with bounded counts, health, and related views.', input = { fields = {
                { key = 'id', label = 'Group ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'membership', label = 'Membership inspector', operation = 'inspect', presentation = 'detail', order = 170,
            description = 'Inspect one membership with bounded roles, duty, assignments, and delegations.', input = { fields = {
                { key = 'id', label = 'Membership ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'relationship', label = 'Relationship inspector', operation = 'inspect', presentation = 'detail', order = 180,
            description = 'Inspect one authorized relationship read model.', input = { fields = {
                { key = 'id', label = 'Relationship ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            } } },
        { id = 'capability', label = 'Capability explain', operation = 'inspect', presentation = 'detail', order = 190,
            description = 'Explain an existing capability decision.', input = { fields = {
                { key = 'id', label = 'Group ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'character_id', label = 'Character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'capability', label = 'Capability', source = 'filter', type = 'string', format = 'capability', required = true, minLength = 1, maxLength = 96 },
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = false, minLength = 1, maxLength = 64 },
                { key = 'scope', label = 'Scope', source = 'filter', type = 'string', format = 'text', required = false, minLength = 1, maxLength = 128 },
            } } },
        { id = 'search', label = 'Find group', operation = 'search', presentation = 'table', order = 200,
            description = 'Exact lookup by public group identifier.' },
        { id = 'findings', label = 'Findings', operation = 'findings', presentation = 'findings', order = 210,
            description = 'Current Groups doctor findings.' },
        { id = 'policy_simulation', label = 'Policy simulation', operation = 'simulate', presentation = 'detail', order = 220,
            description = 'Read-only evaluation of an existing policy.', input = { fields = {
                { key = 'actor_character_id', label = 'Actor character ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'group_id', label = 'Group ID', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
                { key = 'action', label = 'Action', source = 'filter', type = 'string', format = 'action', required = true, minLength = 3, maxLength = 64 },
                { key = 'target_membership_id', label = 'Target membership ID', source = 'filter', type = 'string', format = 'identifier', required = false, minLength = 1, maxLength = 64 },
                { key = 'target_grade_id', label = 'Target grade ID', source = 'filter', type = 'string', format = 'identifier', required = false, minLength = 1, maxLength = 64 },
            } } },
        { id = 'character_relations', label = 'Character relations', operation = 'inspect', presentation = 'detail', order = 230,
            description = 'Bounded organization links for one exact character identifier.' },
    }

    for _, view in ipairs(VIEWS) do
        view.accessClass = 'general'
        if view.id == 'search' then
            view.search = { kinds = {
                { id = 'group', modes = { 'exact' }, accessClass = 'general' },
                { id = 'membership', modes = { 'exact' }, accessClass = 'general' },
            } }
        end
    end

    local function failure(code, message, retryable)
        return Foundation.domainError(code, message, retryable == true)
    end

    local function validateRequest(request, allowed, required)
        local copied, candidate = pcall(Foundation.copyPlain, request, {
            maximumDepth = 5, maximumKeys = 24, maximumStringBytes = 512,
        })
        if not copied then
            return nil, failure('VALIDATION_FAILED', 'The Groups control request is invalid.')
        end
        local allowedMap = {}
        for _, key in ipairs(allowed) do allowedMap[key] = true end
        local valid, validationError = Foundation.validateShape(
            candidate, allowedMap, required or {})
        if not valid then return nil, validationError end
        return candidate, nil
    end

    local function validId(value)
        return Foundation.isPublicId(value)
    end

    local function validText(value, minimum, maximum, pattern)
        return type(value) == 'string' and #value >= minimum and #value <= maximum
            and (pattern == nil or value:match(pattern) ~= nil)
    end

    local function validLimit(value, maximum)
        return value == nil or type(value) == 'number'
            and math.type(value) == 'integer' and value >= 1 and value <= maximum
    end

    local function validCursor(value, maximum)
        return value == nil or type(value) == 'string' and #value >= 1
            and #value <= (maximum or 192)
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function clean(candidate, keys)
        local result = {}
        for _, key in ipairs(keys) do
            if candidate[key] ~= nil then result[key] = candidate[key] end
        end
        return result
    end

    local function exactKeys(candidate, keys)
        local allowed = {}
        for _, key in ipairs(keys) do allowed[key] = true end
        for key in pairs(candidate) do if not allowed[key] then return false end end
        return true
    end

    local function emptyObject(value)
        return value == nil or type(value) == 'table' and next(value) == nil
    end

    local function nested(value, allowed, required)
        return validateRequest(value or {}, allowed, required or {})
    end

    return function(options)
        local database = assert(options.database, 'Groups control provider database is required')
        local methods = assert(options.methods, 'Groups control provider methods are required')
        local query = assert(options.query, 'Groups control provider query function is required')
        local errorSink = assert(options.errorSink, 'Groups control provider error sink is required')
        local getApi = assert(options.getApi, 'Groups control provider API getter is required')

        local function domainContext(context)
            local api = getApi()
            if type(api) ~= 'table' or type(api.ownerEpoch) ~= 'number'
                or math.type(api.ownerEpoch) ~= 'integer' or api.ownerEpoch < 1 then
                return nil, failure('UNAVAILABLE', 'The Groups Core owner epoch is unavailable.', true)
            end
            return {
                caller = 'synex_groups',
                callerEpoch = api.ownerEpoch,
                traceId = type(context) == 'table' and context.traceId or 'control_unavailable',
                deadlineAt = type(context) == 'table' and context.deadlineAt or nil,
            }
        end

        local function invoke(methodName, request, context)
            local handler = methods[methodName]
            if not Foundation.isCallable(handler) then
                return nil, failure('UNAVAILABLE', 'The requested Groups read model is unavailable.', true)
            end
            local internalContext, contextError = domainContext(context)
            if not internalContext then return nil, contextError end
            local called, value, operationError = pcall(handler, request, internalContext)
            if called then return value, operationError end
            pcall(errorSink, {
                operation = 'control_' .. methodName,
                code = 'DATABASE_ERROR',
                traceId = type(context) == 'table' and context.traceId or 'unavailable',
            })
            return nil, failure('DATABASE_ERROR', 'The Groups control read failed.', true)
        end

        local function runQuery(sql, parameters, context)
            local called, rows = pcall(query, sql, parameters or {})
            if called and type(rows) == 'table' then return rows, nil end
            pcall(errorSink, { operation = 'control_query', code = 'DATABASE_ERROR',
                traceId = type(context) == 'table' and context.traceId or 'unavailable' })
            return nil, failure('DATABASE_ERROR', 'The Groups control read failed.', true)
        end

        local function page(rows, limit, cursorField)
            local truncated = #rows > limit
            if truncated then rows[#rows] = nil end
            return { items = rows,
                nextCursor = truncated and rows[#rows] and rows[#rows][cursorField] or nil,
                hasMore = truncated, truncated = truncated }
        end

        local function invokePage(methodName, request, context)
            local value, operationError = invoke(methodName, request, context)
            if not value then return nil, operationError end
            value.nextCursor = value.nextCursor or value.next_cursor
            value.next_cursor = nil
            value.hasMore = value.truncated == true or value.nextCursor ~= nil
            value.truncated = value.hasMore
            return value, nil
        end

        local function graphPage(value, sourceField, targetField, typeField, edgeIdField, defaultType)
            local nodes, edges, seen = {}, {}, {}
            local function node(id)
                if type(id) ~= 'string' or seen[id] then return end
                seen[id] = true
                nodes[#nodes + 1] = { id = id, label = 'Organization', type = 'group' }
            end
            for _, item in ipairs(value.items or {}) do
                local source, target = item[sourceField], item[targetField]
                node(source)
                node(target)
                if source and target then
                    edges[#edges + 1] = {
                        id = item[edgeIdField], from = source, to = target,
                        type = item[typeField] or defaultType or 'relationship',
                    }
                end
            end
            return {
                nodes = nodes, edges = edges, nextCursor = value.nextCursor,
                hasMore = value.hasMore == true, truncated = value.truncated == true,
            }
        end

        local function doctorFindings(value, limit)
            local items = {}
            for _, check in ipairs(value.checks or {}) do
                if check.status ~= 'PASS' and #items < limit then
                    items[#items + 1] = {
                        code = check.key,
                        severity = check.status == 'FAIL' and 'ERROR' or 'WARNING',
                        title = check.key,
                        summary = ('Observed count: %d'):format(tonumber(check.count) or 0),
                    }
                end
            end
            return {
                items = items, hasMore = false, truncated = false, status = value.status,
            }
        end

        local function timelinePage(value, kind)
            local items = {}
            for index, item in ipairs(value.items or {}) do
                if kind == 'duty' then
                    items[index] = {
                        id = item.duty_session_id,
                        timestamp = item.started_at,
                        status = item.status,
                        label = 'Duty · ' .. tostring(item.state or item.status),
                        detail = 'Membership duty lifecycle event',
                        membershipId = item.membership_id,
                    }
                else
                    items[index] = {
                        id = item.event_id,
                        timestamp = item.occurred_at,
                        status = 'INFO',
                        label = item.event_type,
                        detail = tostring(item.entity_type or 'organization') .. ' audit event',
                        entityId = item.entity_id,
                    }
                end
            end
            return {
                items = items, nextCursor = value.nextCursor,
                hasMore = value.hasMore == true, truncated = value.truncated == true,
            }
        end

        local function boundedRelated(rows, limit)
            local truncated = #rows > limit
            if truncated then rows[#rows] = nil end
            return {
                items = rows,
                limit = limit,
                hasMore = truncated,
                truncated = truncated,
            }
        end

        local function inspectCharacterRelations(characterId, limit, context)
            local rows, readError = runQuery([[SELECT
                    `membership`.`public_id` AS `membershipId`,
                    `group_record`.`public_id` AS `groupId`,
                    `group_record`.`group_type` AS `groupType`,
                    `group_record`.`status` AS `groupStatus`,
                    `profile`.`lifecycle_state` AS `membershipState`,
                    CAST(COUNT(*) OVER() AS CHAR) AS `relationCount`
                FROM `synex_group_membership_profiles` AS `profile`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` = `profile`.`membership_id`
                INNER JOIN `synex_groups` AS `group_record`
                    ON `group_record`.`id` = `profile`.`group_id`
                WHERE `profile`.`character_id` = ?
                ORDER BY `membership`.`public_id` ASC
                LIMIT ?]], { characterId, limit }, context)
            if not rows then return nil, readError end
            local total = rows[1] and tonumber(rows[1].relationCount) or 0
            local items = {}
            for index, row in ipairs(rows) do
                items[index] = {
                    membershipId = row.membershipId,
                    groupId = row.groupId,
                    groupType = row.groupType,
                    groupStatus = row.groupStatus,
                    membershipState = row.membershipState,
                }
            end
            local truncated = total > #items
            return {
                view = 'character_relations',
                characterId = characterId,
                count = total,
                items = items,
                limit = limit,
                hasMore = truncated,
                truncated = truncated,
                payloadsExposed = false,
            }, nil
        end

        local function inspectGroup(groupId, context)
            local group, groupError = invoke('get', { group_id = groupId }, context)
            if not group then return nil, groupError end
            local rows, readError = runQuery([[SELECT
                    (SELECT COUNT(*)
                        FROM `synex_group_memberships` AS `membership`
                        INNER JOIN `synex_group_membership_profiles` AS `member_profile`
                            ON `member_profile`.`membership_id` = `membership`.`id`
                        WHERE `membership`.`group_id` = `group_record`.`id`
                            AND `member_profile`.`lifecycle_state` = 'ACTIVE') AS `members`,
                    (SELECT COUNT(*)
                        FROM `synex_group_duty_sessions` AS `duty`
                        INNER JOIN `synex_group_memberships` AS `membership`
                            ON `membership`.`id` = `duty`.`membership_id`
                        INNER JOIN `synex_group_membership_profiles` AS `member_profile`
                            ON `member_profile`.`membership_id` = `membership`.`id`
                        INNER JOIN `synex_group_duty_states` AS `duty_state`
                            ON `duty_state`.`state_key` = `duty`.`state_key`
                        INNER JOIN `synex_group_type_duty_states` AS `allowed_state`
                            ON `allowed_state`.`group_type_id` = `profile`.`group_type_id`
                            AND `allowed_state`.`state_key` = `duty`.`state_key`
                        WHERE `membership`.`group_id` = `group_record`.`id`
                            AND `member_profile`.`lifecycle_state` = 'ACTIVE'
                            AND `duty`.`status` = 'open'
                            AND `duty_state`.`status` = 'active'
                            AND `duty_state`.`counts_as_on_duty` = 1) AS `on_duty`,
                    (SELECT COUNT(*) FROM `synex_group_grades` AS `grade`
                        WHERE `grade`.`group_id` = `group_record`.`id`
                            AND `grade`.`status` = 'active') AS `grades`,
                    (SELECT COUNT(*) FROM `synex_group_roles` AS `role`
                        WHERE `role`.`group_id` = `group_record`.`id`
                            AND `role`.`status` = 'active') AS `roles`,
                    (SELECT COUNT(*)
                        FROM `synex_group_hierarchy_edges` AS `edge`
                        INNER JOIN `synex_group_organization_profiles` AS `child_profile`
                            ON `child_profile`.`group_id` = `edge`.`child_group_id`
                        WHERE `edge`.`parent_group_id` = `group_record`.`id`
                            AND `child_profile`.`lifecycle_state` <> 'DELETED') AS `subgroups`,
                    (SELECT COUNT(*)
                        FROM `synex_group_membership_grades` AS `assigned_grade`
                        INNER JOIN `synex_group_memberships` AS `membership`
                            ON `membership`.`id` = `assigned_grade`.`membership_id`
                        INNER JOIN `synex_group_grades` AS `grade`
                            ON `grade`.`id` = `assigned_grade`.`grade_id`
                        WHERE `membership`.`group_id` = `group_record`.`id`
                            AND `grade`.`group_id` <> `group_record`.`id`)
                    + (SELECT COUNT(*)
                        FROM `synex_group_membership_roles` AS `assigned_role`
                        INNER JOIN `synex_group_memberships` AS `membership`
                            ON `membership`.`id` = `assigned_role`.`membership_id`
                        INNER JOIN `synex_group_roles` AS `role`
                            ON `role`.`id` = `assigned_role`.`role_id`
                        WHERE `membership`.`group_id` = `group_record`.`id`
                            AND `role`.`group_id` <> `group_record`.`id`
                            AND `assigned_role`.`status` = 'active') AS `integrity_issues`
                FROM `synex_groups` AS `group_record`
                INNER JOIN `synex_group_organization_profiles` AS `profile`
                    ON `profile`.`group_id` = `group_record`.`id`
                WHERE `group_record`.`public_id` = ? LIMIT 1]], { groupId }, context)
            if not rows then return nil, readError end
            local counts = rows[1]
            if type(counts) ~= 'table' then
                return nil, failure('DATABASE_RESULT_INVALID',
                    'The Groups inspector counts are unavailable.', true)
            end
            local function count(value)
                local number = tonumber(value)
                if number == nil or math.type(number) ~= 'integer' or number < 0 then
                    return nil
                end
                return number
            end
            local members, onDuty = count(counts.members), count(counts.on_duty)
            local grades, roles = count(counts.grades), count(counts.roles)
            local subgroups, integrityIssues = count(counts.subgroups),
                count(counts.integrity_issues)
            if members == nil or onDuty == nil or grades == nil or roles == nil
                or subgroups == nil or integrityIssues == nil then
                return nil, failure('DATABASE_RESULT_INVALID',
                    'The Groups inspector counts are invalid.', true)
            end
            group.counts = {
                members = members,
                onDuty = onDuty,
                grades = grades,
                roles = roles,
                subgroups = subgroups,
            }
            group.health = {
                status = integrityIssues == 0 and 'HEALTHY' or 'ERROR',
                integrityIssues = integrityIssues,
                scope = 'organization',
            }
            group.links = {
                members = { provider = 'groups', view = 'memberships',
                    filters = { group_id = groupId }, requiresActor = true },
                duty = { provider = 'groups', view = 'duty',
                    filters = { group_id = groupId }, requiresActor = true },
                grades = { provider = 'groups', view = 'grades',
                    filters = { group_id = groupId } },
                roles = { provider = 'groups', view = 'roles',
                    filters = { group_id = groupId } },
                subgroups = { provider = 'groups', view = 'hierarchy',
                    filters = { group_id = groupId } },
            }
            return group, nil
        end

        local function inspectMembership(membershipId, limit, context)
            local membership, membershipError = invoke(
                'members_get', { membership_id = membershipId }, context)
            if not membership then return nil, membershipError end
            local relatedLimit = math.min(limit or 8, 8)
            local queries = {
                roles = [[SELECT `assignment`.`public_id` AS `membership_role_id`,
                        `role`.`public_id` AS `role_id`, `role`.`role_key` AS `key`,
                        `role`.`display_name` AS `name`, `assignment`.`status`,
                        DATE_FORMAT(`assignment`.`valid_from`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_from`,
                        DATE_FORMAT(`assignment`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_until`,
                        CAST(`assignment`.`version` AS CHAR) AS `version`
                    FROM `synex_group_membership_roles` AS `assignment`
                    INNER JOIN `synex_group_memberships` AS `membership`
                        ON `membership`.`id` = `assignment`.`membership_id`
                    INNER JOIN `synex_group_roles` AS `role`
                        ON `role`.`id` = `assignment`.`role_id`
                    WHERE `membership`.`public_id` = ?
                        AND `assignment`.`status` = 'active'
                        AND `assignment`.`valid_from` <= CURRENT_TIMESTAMP(6)
                        AND (`assignment`.`valid_until` IS NULL
                            OR `assignment`.`valid_until` > CURRENT_TIMESTAMP(6))
                        AND `role`.`status` = 'active'
                    ORDER BY `role`.`role_key`, `assignment`.`public_id` LIMIT ?]],
                duty = [[SELECT `duty`.`public_id` AS `duty_session_id`,
                        `duty`.`state_key` AS `state`, `duty`.`status`,
                        `assignment`.`public_id` AS `assignment_id`,
                        CASE WHEN `duty_state`.`status` = 'active'
                                AND `allowed_state`.`state_key` IS NOT NULL
                                AND `duty_state`.`counts_as_on_duty` = 1
                            THEN 1 ELSE 0 END AS `counts_as_on_duty`,
                        DATE_FORMAT(`duty`.`started_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `started_at`,
                        DATE_FORMAT(`duty`.`ended_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `ended_at`,
                        CAST(`duty`.`version` AS CHAR) AS `version`
                    FROM `synex_group_duty_sessions` AS `duty`
                    INNER JOIN `synex_group_memberships` AS `membership`
                        ON `membership`.`id` = `duty`.`membership_id`
                    LEFT JOIN `synex_group_assignments` AS `assignment`
                        ON `assignment`.`id` = `duty`.`assignment_id`
                    LEFT JOIN `synex_group_duty_states` AS `duty_state`
                        ON `duty_state`.`state_key` = `duty`.`state_key`
                    INNER JOIN `synex_group_organization_profiles` AS `profile`
                        ON `profile`.`group_id` = `membership`.`group_id`
                    LEFT JOIN `synex_group_type_duty_states` AS `allowed_state`
                        ON `allowed_state`.`group_type_id` = `profile`.`group_type_id`
                        AND `allowed_state`.`state_key` = `duty`.`state_key`
                    WHERE `membership`.`public_id` = ? AND `duty`.`status` = 'open'
                    ORDER BY `duty`.`public_id` LIMIT ?]],
                assignments = [[SELECT `assignment`.`public_id` AS `assignment_id`,
                        `assignment`.`assignment_key` AS `key`,
                        `assignment`.`display_name` AS `name`,
                        `assignment`.`status`, `participant`.`role_key`,
                        DATE_FORMAT(`participant`.`joined_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `joined_at`,
                        CAST(`participant`.`version` AS CHAR) AS `version`
                    FROM `synex_group_assignment_members` AS `participant`
                    INNER JOIN `synex_group_memberships` AS `membership`
                        ON `membership`.`id` = `participant`.`membership_id`
                    INNER JOIN `synex_group_assignments` AS `assignment`
                        ON `assignment`.`id` = `participant`.`assignment_id`
                    WHERE `membership`.`public_id` = ? AND `participant`.`status` = 'active'
                        AND `assignment`.`status` = 'active'
                        AND `assignment`.`valid_from` <= CURRENT_TIMESTAMP(6)
                        AND (`assignment`.`valid_until` IS NULL
                            OR `assignment`.`valid_until` > CURRENT_TIMESTAMP(6))
                    ORDER BY `assignment`.`public_id` LIMIT ?]],
                delegations = [[SELECT `delegation`.`public_id` AS `delegation_id`,
                        `grantor`.`public_id` AS `grantor_membership_id`,
                        `grantee`.`public_id` AS `grantee_membership_id`,
                        `delegation`.`capability_pattern`, `delegation`.`scope_kind`,
                        `delegation`.`scope_ref`, `delegation`.`status`,
                        DATE_FORMAT(`delegation`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_until`,
                        CAST(`delegation`.`version` AS CHAR) AS `version`
                    FROM `synex_group_delegations` AS `delegation`
                    INNER JOIN `synex_group_memberships` AS `grantor`
                        ON `grantor`.`id` = `delegation`.`grantor_membership_id`
                    INNER JOIN `synex_group_memberships` AS `grantee`
                        ON `grantee`.`id` = `delegation`.`grantee_membership_id`
                    WHERE `grantee`.`public_id` = ?
                        AND `delegation`.`status` = 'active'
                        AND `delegation`.`valid_from` <= CURRENT_TIMESTAMP(6)
                        AND `delegation`.`valid_until` > CURRENT_TIMESTAMP(6)
                    ORDER BY `delegation`.`public_id` LIMIT ?]],
            }
            local sections = {}
            for _, name in ipairs({ 'roles', 'duty', 'assignments', 'delegations' }) do
                local parameters = { membershipId, relatedLimit + 1 }
                local rows, readError = runQuery(queries[name], parameters, context)
                if not rows then return nil, readError end
                sections[name] = boundedRelated(rows, relatedLimit)
            end
            membership.roles = sections.roles
            membership.duty = sections.duty
            membership.assignments = sections.assignments
            membership.delegations = sections.delegations
            membership.delegations.scope = 'effective_received'
            membership.links = {
                group = { provider = 'groups', view = 'group', id = membership.group_id },
            }
            return membership, nil
        end

        local handlers = {}

        handlers.summary = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'limit' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'overview' or not validLimit(candidate.limit, 100) then
                return nil, failure('VALIDATION_FAILED', 'The Groups summary view is invalid.')
            end
            local called, value, summaryError = pcall(database.getControlSummary, database)
            if not called then
                return nil, failure('DATABASE_ERROR', 'The Groups summary is unavailable.', true)
            end
            if not value then return nil, summaryError end
            local doctor, doctorError = invoke('doctor', {}, context)
            if not doctor then return nil, doctorError end
            value.status = ({
                PASS = 'HEALTHY', WARN = 'WARNING', FAIL = 'ERROR',
            })[doctor.status] or 'UNAVAILABLE'
            value.doctorStatus = doctor.status
            return value, nil
        end

        handlers.health = function(request, context)
            local candidate, requestError = validateRequest(
                request, { 'view', 'limit' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'health' or not validLimit(candidate.limit, 100) then
                return nil, failure('VALIDATION_FAILED', 'The Groups health view is invalid.')
            end
            local doctor, doctorError = invoke('doctor', {}, context)
            if not doctor then return nil, doctorError end
            doctor.doctorStatus = doctor.status
            doctor.status = ({ PASS = 'HEALTHY', WARN = 'WARNING',
                FAIL = 'ERROR' })[doctor.status] or 'UNAVAILABLE'
            return doctor, nil
        end

        handlers.list = function(request, context)
            local candidate, requestError = validateRequest(request, {
                'view', 'cursor', 'limit', 'filters', 'sort',
            }, { 'view' })
            if not candidate then return nil, requestError end
            if not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED',
                    'Groups control lists use a fixed stable order.')
            end
            if candidate.view == 'groups' then
                local filters, filterError = nested(candidate.filters,
                    { 'type', 'status', 'parent_group_id' })
                if not filters then return nil, filterError end
                if not validLimit(candidate.limit, 100)
                    or candidate.cursor ~= nil and not validId(candidate.cursor)
                    or filters.parent_group_id ~= nil and not validId(filters.parent_group_id)
                    or filters.type ~= nil and not validText(filters.type, 2, 64, '^[a-z][a-z0-9_-]*$') then
                    return nil, failure('VALIDATION_FAILED', 'The Groups list bounds are invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                return invokePage('list', filters, context)
            end
            if candidate.view == 'memberships' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id', 'actor_character_id', 'status' },
                    { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id)
                    or not Foundation.isSubjectId(filters.actor_character_id)
                    or not validLimit(candidate.limit, 100)
                    or candidate.cursor ~= nil and not validId(candidate.cursor) then
                    return nil, failure('VALIDATION_FAILED', 'The membership list request is invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                return invokePage('members_list', filters, context)
            end
            if candidate.view == 'hierarchy' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id' }, { 'group_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id) or not validLimit(candidate.limit, 50)
                    or not validCursor(candidate.cursor, 48) then
                    return nil, failure('VALIDATION_FAILED', 'The hierarchy list request is invalid.')
                end
                local sql = [[SELECT `child`.`public_id` AS `child_group_id`,
                        `parent`.`public_id` AS `parent_group_id`, `edge`.`reason_code`,
                        CAST(`edge`.`version` AS CHAR) AS `version`,
                        DATE_FORMAT(`edge`.`updated_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `updated_at`
                    FROM `synex_group_hierarchy_edges` AS `edge`
                    INNER JOIN `synex_groups` AS `child` ON `child`.`id` = `edge`.`child_group_id`
                    INNER JOIN `synex_groups` AS `parent` ON `parent`.`id` = `edge`.`parent_group_id`
                    WHERE (`child`.`public_id` = ? OR `parent`.`public_id` = ?)]]
                local parameters = { filters.group_id, filters.group_id }
                if candidate.cursor then
                    sql = sql .. ' AND `child`.`public_id` > ?'
                    parameters[#parameters + 1] = candidate.cursor
                end
                sql = sql .. ' ORDER BY `child`.`public_id` ASC LIMIT ?'
                local limit = candidate.limit or 20
                parameters[#parameters + 1] = limit + 1
                local rows, readError = runQuery(sql, parameters, context)
                if not rows then return nil, readError end
                return graphPage(page(rows, limit, 'child_group_id'),
                    'parent_group_id', 'child_group_id', 'edge_type', 'child_group_id', 'parent'), nil
            end
            if candidate.view == 'roles' or candidate.view == 'grades'
                or candidate.view == 'delegations' or candidate.view == 'policies' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id', 'status' }, { 'group_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id) or not validLimit(candidate.limit, 50)
                    or not validCursor(candidate.cursor, 48) then
                    return nil, failure('VALIDATION_FAILED', 'The group-owned list request is invalid.')
                end
                local definitions = {
                    roles = {
                        prefix = [[SELECT `role`.`public_id` AS `item_id`,
                                `group`.`public_id` AS `group_id`, `role`.`role_key`,
                                `role`.`display_name`, `role`.`exclusivity`, `role`.`holder_limit`,
                                `role`.`status`, CAST(`role`.`version` AS CHAR) AS `version`
                            FROM `synex_group_roles` AS `role`
                            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `role`.`group_id`]],
                        id = '`role`.`public_id`', status = '`role`.`status`',
                    },
                    grades = {
                        prefix = [[SELECT `grade`.`public_id` AS `item_id`,
                                `group`.`public_id` AS `group_id`, `grade`.`grade_key`,
                                `grade`.`display_name`, `grade`.`rank_value`, `grade`.`status`,
                                CAST(`grade`.`version` AS CHAR) AS `version`
                            FROM `synex_group_grades` AS `grade`
                            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`]],
                        id = '`grade`.`public_id`', status = '`grade`.`status`',
                    },
                    delegations = {
                        prefix = [[SELECT `delegation`.`public_id` AS `item_id`,
                                `group`.`public_id` AS `group_id`,
                                `grantor`.`public_id` AS `grantor_membership_id`,
                                `grantee`.`public_id` AS `grantee_membership_id`,
                                `delegation`.`capability_pattern`, `delegation`.`scope_kind`,
                                `delegation`.`scope_ref`, `delegation`.`status`,
                                DATE_FORMAT(`delegation`.`valid_until`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `valid_until`,
                                CAST(`delegation`.`version` AS CHAR) AS `version`
                            FROM `synex_group_delegations` AS `delegation`
                            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `delegation`.`group_id`
                            INNER JOIN `synex_group_memberships` AS `grantor`
                                ON `grantor`.`id` = `delegation`.`grantor_membership_id`
                            INNER JOIN `synex_group_memberships` AS `grantee`
                                ON `grantee`.`id` = `delegation`.`grantee_membership_id`]],
                        id = '`delegation`.`public_id`', status = '`delegation`.`status`',
                    },
                    policies = {
                        prefix = [[SELECT `policy`.`public_id` AS `item_id`,
                                `group`.`public_id` AS `group_id`, `policy`.`policy_key`,
                                `policy`.`display_name`, `policy`.`status`,
                                `policy`.`default_effect`, CAST(`policy`.`version` AS CHAR) AS `version`
                            FROM `synex_group_policies` AS `policy`
                            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `policy`.`group_id`]],
                        id = '`policy`.`public_id`', status = '`policy`.`status`',
                    },
                }
                local definition = definitions[candidate.view]
                local sql = definition.prefix .. ' WHERE `group`.`public_id` = ?'
                local parameters = { filters.group_id }
                if candidate.cursor then
                    sql = sql .. ' AND ' .. definition.id .. ' > ?'
                    parameters[#parameters + 1] = candidate.cursor
                end
                if filters.status then
                    if not validText(filters.status, 2, 16, '^[a-z_]+$') then
                        return nil, failure('VALIDATION_FAILED', 'The group-owned status filter is invalid.')
                    end
                    sql = sql .. ' AND ' .. definition.status .. ' = ?'
                    parameters[#parameters + 1] = filters.status
                end
                local limit = candidate.limit or 20
                sql = sql .. ' ORDER BY ' .. definition.id .. ' ASC LIMIT ?'
                parameters[#parameters + 1] = limit + 1
                local rows, readError = runQuery(sql, parameters, context)
                if not rows then return nil, readError end
                return page(rows, limit, 'item_id'), nil
            end
            if candidate.view == 'capabilities' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id' }, { 'group_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id) or not validLimit(candidate.limit, 50)
                    or not validCursor(candidate.cursor, 192) then
                    return nil, failure('VALIDATION_FAILED', 'The capability list request is invalid.')
                end
                local sql = [[SELECT * FROM (
                        SELECT CONCAT('role:', `role`.`public_id`, ':', `rule`.`id`) AS `cursor_key`,
                            'role' AS `source_kind`, `role`.`public_id` AS `source_id`,
                            `group`.`public_id` AS `group_id`, `rule`.`capability_pattern`,
                            `rule`.`effect`, `rule`.`scope_kind`, `rule`.`scope_ref`,
                            CAST(`rule`.`version` AS CHAR) AS `version`
                        FROM `synex_group_role_capabilities` AS `rule`
                        INNER JOIN `synex_group_roles` AS `role` ON `role`.`id` = `rule`.`role_id`
                        INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `role`.`group_id`
                        WHERE `group`.`public_id` = ?
                        UNION ALL
                        SELECT CONCAT('grade:', `grade`.`public_id`, ':', `rule`.`id`) AS `cursor_key`,
                            'grade' AS `source_kind`, `grade`.`public_id` AS `source_id`,
                            `group`.`public_id` AS `group_id`, `rule`.`capability_pattern`,
                            `rule`.`effect`, COALESCE(`scope`.`scope_kind`, 'group') AS `scope_kind`,
                            COALESCE(`scope`.`scope_ref`, '') AS `scope_ref`,
                            CAST(`rule`.`version` AS CHAR) AS `version`
                        FROM `synex_group_grade_capabilities` AS `rule`
                        INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`id` = `rule`.`grade_id`
                        INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `grade`.`group_id`
                        LEFT JOIN `synex_group_grade_capability_scopes` AS `scope`
                            ON `scope`.`grade_capability_id` = `rule`.`id`
                        WHERE `group`.`public_id` = ?
                    ) AS `capability`]]
                local parameters = { filters.group_id, filters.group_id }
                if candidate.cursor then
                    sql = sql .. ' WHERE `cursor_key` > ?'
                    parameters[#parameters + 1] = candidate.cursor
                end
                local limit = candidate.limit or 20
                sql = sql .. ' ORDER BY `cursor_key` ASC LIMIT ?'
                parameters[#parameters + 1] = limit + 1
                local rows, readError = runQuery(sql, parameters, context)
                if not rows then return nil, readError end
                return page(rows, limit, 'cursor_key'), nil
            end
            if candidate.view == 'duty' then
                local filters, filterError = nested(candidate.filters, {
                    'group_id', 'actor_character_id', 'membership_id', 'status',
                }, { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id)
                    or not Foundation.isSubjectId(filters.actor_character_id)
                    or filters.membership_id ~= nil and not validId(filters.membership_id)
                    or not validLimit(candidate.limit, 100)
                    or not validCursor(candidate.cursor, 48) then
                    return nil, failure('VALIDATION_FAILED', 'The duty list request is invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                local value, listError = invokePage('duty_list', filters, context)
                if not value then return nil, listError end
                return timelinePage(value, 'duty'), nil
            end
            if candidate.view == 'assignments' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id', 'actor_character_id', 'status' },
                    { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id)
                    or not Foundation.isSubjectId(filters.actor_character_id)
                    or not validLimit(candidate.limit, 100)
                    or not validCursor(candidate.cursor, 48) then
                    return nil, failure('VALIDATION_FAILED', 'The assignment list request is invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                return invokePage('assignments_list', filters, context)
            end
            if candidate.view == 'relationships' then
                local filters, filterError = nested(candidate.filters, {
                    'group_id', 'actor_character_id', 'relation_type', 'direction', 'status',
                }, { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id)
                    or not Foundation.isSubjectId(filters.actor_character_id)
                    or not validLimit(candidate.limit, 40)
                    or candidate.cursor ~= nil and not validId(candidate.cursor) then
                    return nil, failure('VALIDATION_FAILED', 'The relationship list request is invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                local value, listError = invokePage('relationships_list', filters, context)
                if not value then return nil, listError end
                return graphPage(value, 'source_group_id', 'target_group_id',
                    'relation_type', 'relationship_id'), nil
            end
            if candidate.view == 'history' then
                local filters, filterError = nested(candidate.filters, {
                    'group_id', 'actor_character_id', 'entity_type', 'entity_id',
                }, { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if not validId(filters.group_id)
                    or not Foundation.isSubjectId(filters.actor_character_id)
                    or not validLimit(candidate.limit, 100)
                    or candidate.cursor ~= nil and not validId(candidate.cursor)
                    or filters.entity_id ~= nil and not validId(filters.entity_id) then
                    return nil, failure('VALIDATION_FAILED', 'The Groups history request is invalid.')
                end
                filters.cursor, filters.limit = candidate.cursor, candidate.limit
                local value, listError = invokePage('history_list', filters, context)
                if not value then return nil, listError end
                return timelinePage(value, 'history'), nil
            end
            return nil, failure('VALIDATION_FAILED', 'The Groups list view is invalid.')
        end

        handlers.inspect = function(request, context)
            local candidate, requestError = validateRequest(request, {
                'view', 'id', 'cursor', 'limit', 'filters', 'sort',
            }, { 'view', 'id' })
            if not candidate then return nil, requestError end
            if not validId(candidate.id) or candidate.cursor ~= nil
                or not validLimit(candidate.limit, 25) or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED', 'The Groups inspection bounds are invalid.')
            end
            if candidate.view == 'group' and emptyObject(candidate.filters) then
                return inspectGroup(candidate.id, context)
            end
            if candidate.view == 'membership' and emptyObject(candidate.filters) then
                return inspectMembership(candidate.id, candidate.limit, context)
            end
            if candidate.view == 'character_relations' and emptyObject(candidate.filters)
                and candidate.cursor == nil and validLimit(candidate.limit, 8)
                and Foundation.isSubjectId(candidate.id) then
                return inspectCharacterRelations(candidate.id, candidate.limit or 8, context)
            end
            if candidate.view == 'relationship' then
                local filters, filterError = nested(candidate.filters,
                    { 'group_id', 'actor_character_id' },
                    { 'group_id', 'actor_character_id' })
                if not filters then return nil, filterError end
                if validId(filters.group_id)
                    and Foundation.isSubjectId(filters.actor_character_id) then
                    filters.relationship_id = candidate.id
                    return invoke('relationships_get', filters, context)
                end
            end
            if candidate.view == 'capability' then
                local filters, filterError = nested(candidate.filters, {
                    'character_id', 'actor_character_id', 'capability', 'scope',
                }, { 'character_id', 'capability' })
                if not filters then return nil, filterError end
                if Foundation.isSubjectId(filters.character_id)
                    and validText(filters.capability, 1, 96, '^[a-z][a-z0-9._*-]*$') then
                    filters.group_id = candidate.id
                    return invoke('capabilities_explain', filters, context)
                end
            end
            return nil, failure('VALIDATION_FAILED', 'The Groups inspection request is invalid.')
        end

        handlers.search = function(request, context)
            local candidate, requestError = validateRequest(request,
                { 'query', 'cursor', 'limit', 'filters', 'sort' }, { 'query' })
            if not candidate then return nil, requestError end
            local query, queryError = nested(candidate.query,
                { 'kind', 'value', 'mode' }, { 'kind', 'value', 'mode' })
            if not query then return nil, queryError end
            if query.mode ~= 'exact' or not validId(query.value)
                or candidate.cursor ~= nil or not validLimit(candidate.limit, 25)
                or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED',
                    'Groups search supports bounded exact identifiers only; prefix mode is unsupported.')
            end
            local method, domainRequest
            if query.kind == 'group' then
                method, domainRequest = 'get', { group_id = query.value }
            elseif query.kind == 'membership' then
                method, domainRequest = 'members_get', { membership_id = query.value }
            else
                return nil, failure('VALIDATION_FAILED', 'The Groups search kind is invalid.')
            end
            local value, searchError = invoke(method, domainRequest, context)
            if not value then return nil, searchError end
            return { items = {{ kind = query.kind, id = query.value, result = value }},
                hasMore = false, truncated = false }, nil
        end

        handlers.findings = function(request, context)
            local candidate, requestError = validateRequest(request,
                { 'view', 'cursor', 'limit', 'filters', 'sort' }, { 'view' })
            if not candidate then return nil, requestError end
            if candidate.view ~= 'findings' and candidate.view ~= 'drift'
                or candidate.cursor ~= nil
                or not validLimit(candidate.limit, 100)
                or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
                return nil, failure('VALIDATION_FAILED', 'The Groups findings view is invalid.')
            end
            local value, doctorError = invoke('doctor', {}, context)
            if not value then return nil, doctorError end
            return doctorFindings(value, candidate.limit or 25), nil
        end

        handlers.simulate = function(request, context)
            local candidate, requestError = validateRequest(request,
                { 'view', 'filters', 'limit' }, { 'view', 'filters' })
            if not candidate then return nil, requestError end
            local filters, filterError = nested(candidate.filters, {
                'actor_character_id', 'group_id', 'action', 'target_membership_id',
                'target_grade_id',
            }, { 'actor_character_id', 'group_id', 'action' })
            if not filters then return nil, filterError end
            if candidate.view ~= 'policy_simulation' or not validLimit(candidate.limit, 25)
                or not Foundation.isSubjectId(filters.actor_character_id)
                or not validId(filters.group_id)
                or not validText(filters.action, 3, 64, '^[a-z][a-z0-9_.%-]*$')
                or filters.target_membership_id ~= nil
                    and not validId(filters.target_membership_id)
                or filters.target_grade_id ~= nil and not validId(filters.target_grade_id) then
                return nil, failure('VALIDATION_FAILED', 'The policy simulation request is invalid.')
            end
            local domainRequest = {
                actor_character_id = filters.actor_character_id,
                group_id = filters.group_id,
                action = filters.action,
                target_membership_id = filters.target_membership_id,
                parameters = filters.target_grade_id and {
                    target_grade_id = filters.target_grade_id,
                } or nil,
            }
            return invoke('policies_simulate', domainRequest, context)
        end

        local boundaryHandlers = {}
        for operation, handler in pairs(handlers) do
            boundaryHandlers[operation] = function(...)
                local value, operationError = handler(...)
                if value == nil and operationError ~= nil then return false, operationError end
                return value, operationError
            end
        end

        local provider = {}
        function provider:register(api)
            local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
                and api.ControlProviders.register or nil
            if not Foundation.isCallable(register) then
                return nil, failure('UNAVAILABLE', 'The Core control-provider registry is unavailable.', true)
            end
            local called, metadata, registrationError = pcall(register, {
                schemaVersion = 1,
                namespace = 'groups',
                label = 'Groups',
                category = 'domain',
                version = '1.0.0',
                operations = boundaryHandlers,
                views = VIEWS,
            })
            if called and metadata then return metadata, nil end
            return nil, type(registrationError) == 'table' and registrationError
                or failure('UNAVAILABLE', 'The Groups control provider could not be registered.', true)
        end

        provider.operations = OPERATIONS
        provider.views = VIEWS
        return provider
    end
end
