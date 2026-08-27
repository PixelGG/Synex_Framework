return function(port, context)
    local domainError = context.domainError
    local jsonEncode = context.jsonEncode
    local many = context.many
    local one = context.one
    local random = context.random
    local uuidV4 = context.uuidV4
    local withTransaction = context.withTransaction
    local cache = context.cache
    local function invalidateCharacter(characterId)
        if type(cache) ~= 'table' or type(cache.invalidatePrefix) ~= 'function' then return end
        cache:invalidatePrefix('character:' .. characterId)
        -- Membership cache keys are public membership IDs and cannot be
        -- enumerated from the cache. Character deletion is rare, so a
        -- conservative prefix invalidation is preferable to leaking stale PII.
        cache:invalidatePrefix('membership:')
    end

    function port:listSubjectMemberships(subjectKind, subjectId)
        local rows = many([[SELECT `group`.`public_id` AS `group_public_id`, `group`.`group_key`,
                `group`.`group_type`, `group`.`display_name` AS `group_display_name`,
                `membership`.`public_id` AS `membership_public_id`,
                `grade`.`public_id` AS `grade_public_id`, `grade`.`grade_key`,
                `grade`.`display_name` AS `grade_display_name`, `grade`.`rank_value`,
                CASE WHEN `primary`.`membership_id` = `membership`.`id` THEN 1 ELSE 0 END AS `is_primary`,
                `model`.`model_version`
            FROM `synex_group_memberships` AS `membership`
            INNER JOIN `synex_groups` AS `group` ON `group`.`id` = `membership`.`group_id`
            INNER JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
            INNER JOIN `synex_group_membership_grades` AS `assigned`
                ON `assigned`.`membership_id` = `membership`.`id`
            INNER JOIN `synex_group_grades` AS `grade` ON `grade`.`id` = `assigned`.`grade_id`
            LEFT JOIN `synex_group_primary_memberships_by_type` AS `primary`
                ON `primary`.`membership_id` = `membership`.`id`
            WHERE `membership`.`subject_kind` = ? AND `membership`.`subject_ref` = ?
                AND `membership`.`status` = 'active' AND `group`.`status` = 'active'
                AND `grade`.`status` = 'active'
            ORDER BY `is_primary` DESC, `grade`.`rank_value` DESC, `group`.`group_key` ASC
            LIMIT 65]], { subjectKind, subjectId })
        local result = {}
        for index = 1, math.min(#rows, 64) do
            local row = rows[index]
            result[index] = {
                group_id = row.group_public_id,
                group_key = row.group_key,
                group_type = row.group_type,
                group_display_name = row.group_display_name,
                membership_id = row.membership_public_id,
                grade_id = row.grade_public_id,
                grade_key = row.grade_key,
                grade_display_name = row.grade_display_name,
                rank_value = tonumber(row.rank_value),
                is_primary = tonumber(row.is_primary) == 1,
                read_model_version = tonumber(row.model_version),
            }
        end
        return { memberships = result, truncated = #rows > 64 }, nil
    end

    function port:getCharacterLifecycleSummary(characterId)
        local row = one([[SELECT
                (SELECT COUNT(*) FROM `synex_group_memberships`
                    WHERE `subject_kind` = 'character' AND `subject_ref` = ?) AS `membership_count`,
                (SELECT COUNT(*) FROM `synex_group_memberships` AS `membership`
                    INNER JOIN `synex_group_membership_profiles` AS `profile`
                        ON `profile`.`membership_id` = `membership`.`id`
                    WHERE `membership`.`subject_kind` = 'character'
                        AND `membership`.`subject_ref` = ?
                        AND `profile`.`lifecycle_state` = 'ACTIVE')
                    AS `active_membership_count`,
                (SELECT COUNT(*) FROM `synex_group_primary_memberships_by_type`
                    WHERE `character_id` = ?) AS `primary_count`]],
            { characterId, characterId, characterId })
        return {
            memberships = tonumber(row and row.membership_count) or 0,
            activeMemberships = tonumber(row and row.active_membership_count) or 0,
            primaryMemberships = tonumber(row and row.primary_count) or 0,
        }, nil
    end

    function port:applyCharacterDeletion(planId, characterId, anonymousRef)
        local existing = one([[SELECT `anonymous_ref`, `membership_count`, `primary_count`, `state`
            FROM `synex_group_character_deletions` WHERE `plan_id` = ?]], { planId })
        if existing and existing.state == 'completed' then
            invalidateCharacter(characterId)
            return {
                anonymousRef = existing.anonymous_ref,
                memberships = tonumber(existing.membership_count) or 0,
                primaryMemberships = tonumber(existing.primary_count) or 0,
                state = 'completed',
            }, nil
        end

        local eventId = uuidV4(random)
        local result
        local domainFailure
        local committed, transactionError = withTransaction(function(query)
            local journal = query([[SELECT `anonymous_ref`, `membership_count`, `primary_count`, `state`
                FROM `synex_group_character_deletions` WHERE `plan_id` = ? FOR UPDATE]], { planId })
            if journal and journal[1] and journal[1].state == 'completed' then
                result = {
                    anonymousRef = journal[1].anonymous_ref,
                    memberships = tonumber(journal[1].membership_count) or 0,
                    primaryMemberships = tonumber(journal[1].primary_count) or 0,
                    state = 'completed',
                }
                return true
            end
            if not journal or not journal[1] then
                query([[INSERT INTO `synex_group_character_deletions`
                    (`plan_id`, `anonymous_ref`, `state`) VALUES (?, ?, 'pending')]],
                    { planId, anonymousRef })
            elseif journal[1].anonymous_ref ~= anonymousRef then
                domainFailure = domainError('DELETE_PLAN_CONFLICT',
                    'The deletion plan was replayed with different metadata.')
                return false
            end

            local memberships = query([[SELECT `id`, `group_id` FROM `synex_group_memberships`
                WHERE `subject_kind` = 'character' AND `subject_ref` = ? FOR UPDATE]], { characterId }) or {}
            local primaryByType = query([[SELECT `membership_id`
                FROM `synex_group_primary_memberships_by_type`
                WHERE `character_id` = ? FOR UPDATE]], { characterId }) or {}
            local legacyPrimary = query([[SELECT `membership_id`
                FROM `synex_group_primary_memberships`
                WHERE `subject_kind` = 'character' AND `subject_ref` = ? FOR UPDATE]],
                { characterId }) or {}
            local primaryIds = {}
            for _, row in ipairs(primaryByType) do primaryIds[tostring(row.membership_id)] = true end
            for _, row in ipairs(legacyPrimary) do primaryIds[tostring(row.membership_id)] = true end
            local primaryCount = 0
            for _ in pairs(primaryIds) do primaryCount = primaryCount + 1 end
            local response = {
                anonymousRef = anonymousRef,
                memberships = #memberships,
                primaryMemberships = primaryCount,
                state = 'completed',
            }
            local responseJson = jsonEncode(response)

            query([[UPDATE `synex_group_read_model_versions` AS `model`
                INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`group_id` = `model`.`group_id`
                SET `model`.`model_version` = `model`.`model_version` + 1,
                    `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                WHERE `membership`.`subject_kind` = 'character' AND `membership`.`subject_ref` = ?]],
                { characterId })
            query([[INSERT INTO `synex_group_duty_events`
                (`event_id`, `duty_session_id`, `session_version`, `event_type`,
                 `state_key`, `actor_ref`, `reason_code`, `assignment_id`, `metadata_json`)
                SELECT CONCAT('gduty_', SUBSTRING(SHA2(
                        CONCAT(`session`.`public_id`, ':character-delete:', ?), 256), 1, 32)),
                    `session`.`id`, `session`.`version` + 1, 'ended', `session`.`state_key`,
                    ?, 'character_deleted', `session`.`assignment_id`,
                    JSON_OBJECT('reason', 'character_deleted')
                FROM `synex_group_duty_sessions` AS `session`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` = `session`.`membership_id`
                WHERE `membership`.`subject_kind` = 'character'
                    AND `membership`.`subject_ref` = ? AND `session`.`status` = 'open']]
                , { planId, anonymousRef, characterId })
            query([[UPDATE `synex_group_duty_sessions` AS `session`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` = `session`.`membership_id`
                SET `session`.`status` = 'closed', `session`.`ended_at` = CURRENT_TIMESTAMP(6),
                    `session`.`reason_code` = 'character_deleted',
                    `session`.`version` = `session`.`version` + 1
                WHERE `membership`.`subject_kind` = 'character'
                    AND `membership`.`subject_ref` = ? AND `session`.`status` = 'open']],
                { characterId })
            query([[UPDATE `synex_group_membership_roles` AS `assigned`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` = `assigned`.`membership_id`
                SET `assigned`.`status` = 'revoked',
                    `assigned`.`revoked_at` = CURRENT_TIMESTAMP(6),
                    `assigned`.`reason_code` = 'character_deleted',
                    `assigned`.`version` = `assigned`.`version` + 1
                WHERE `membership`.`subject_kind` = 'character'
                    AND `membership`.`subject_ref` = ? AND `assigned`.`status` = 'active']],
                { characterId })
            query([[UPDATE `synex_group_assignment_members` AS `assigned`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` = `assigned`.`membership_id`
                SET `assigned`.`status` = 'removed',
                    `assigned`.`left_at` = CURRENT_TIMESTAMP(6),
                    `assigned`.`reason_code` = 'character_deleted',
                    `assigned`.`version` = `assigned`.`version` + 1
                WHERE `membership`.`subject_kind` = 'character'
                    AND `membership`.`subject_ref` = ? AND `assigned`.`status` = 'active']],
                { characterId })
            query([[UPDATE `synex_group_delegations` AS `delegation`
                INNER JOIN `synex_group_memberships` AS `membership`
                    ON `membership`.`id` IN
                        (`delegation`.`grantor_membership_id`, `delegation`.`grantee_membership_id`)
                SET `delegation`.`status` = 'revoked',
                    `delegation`.`revoked_at` = CURRENT_TIMESTAMP(6),
                    `delegation`.`reason_code` = 'character_deleted',
                    `delegation`.`version` = `delegation`.`version` + 1
                WHERE `membership`.`subject_kind` = 'character'
                    AND `membership`.`subject_ref` = ? AND `delegation`.`status` = 'active']],
                { characterId })
            query([[UPDATE `synex_group_invitations`
                SET `character_id` = ?,
                    `status` = CASE WHEN `status` = 'pending' THEN 'revoked' ELSE `status` END,
                    `responded_at` = CASE WHEN `status` = 'pending'
                        THEN CURRENT_TIMESTAMP(6) ELSE `responded_at` END,
                    `reason_code` = CASE WHEN `status` = 'pending'
                        THEN 'character_deleted' ELSE `reason_code` END,
                    `version` = `version` + 1
                WHERE `character_id` = ?]], { anonymousRef, characterId })
            query([[UPDATE `synex_group_applications`
                SET `character_id` = ?, `application_json` = '{}',
                    `status` = CASE WHEN `status` IN ('submitted', 'reviewing')
                        THEN 'withdrawn' ELSE `status` END,
                    `reviewed_at` = CASE WHEN `status` IN ('submitted', 'reviewing')
                        THEN CURRENT_TIMESTAMP(6) ELSE `reviewed_at` END,
                    `version` = `version` + 1
                WHERE `character_id` = ?]], { anonymousRef, characterId })
            -- A deleted creator or approver can no longer satisfy the
            -- immediately-before-execution permission recheck. Terminalize all
            -- affected non-executed requests before anonymizing their journal.
            query([[DELETE `reservation`
                FROM `synex_group_slug_reservations` AS `reservation`
                INNER JOIN `synex_group_creation_requests` AS `request`
                    ON `request`.`public_id` = `reservation`.`owner_public_id`
                    AND `request`.`requested_slug` = `reservation`.`slug`
                    AND `reservation`.`owner_kind` = 'creation_request'
                INNER JOIN `synex_group_creation_approvals` AS `decision`
                    ON `decision`.`creation_request_id` = `request`.`id`
                WHERE `decision`.`approver_character_ref` = ?
                    AND `request`.`status` IN ('pending', 'approved')]], { characterId })
            query([[DELETE `reservation`
                FROM `synex_group_slug_reservations` AS `reservation`
                INNER JOIN `synex_group_creation_requests` AS `request`
                    ON `request`.`public_id` = `reservation`.`owner_public_id`
                    AND `request`.`requested_slug` = `reservation`.`slug`
                    AND `reservation`.`owner_kind` = 'creation_request'
                WHERE `request`.`status` IN ('pending', 'approved')
                    AND (`request`.`requested_by_ref` = ?
                        OR JSON_SEARCH(`request`.`request_json`, 'one', ?) IS NOT NULL)]],
                { characterId, characterId })
            query([[UPDATE `synex_group_creation_requests` AS `request`
                INNER JOIN `synex_group_creation_approvals` AS `decision`
                    ON `decision`.`creation_request_id` = `request`.`id`
                SET `request`.`status` = 'rejected',
                    `request`.`failure_code` = 'APPROVER_DELETED',
                    `request`.`completed_at` = CURRENT_TIMESTAMP(6),
                    `request`.`version` = `request`.`version` + 1
                WHERE `decision`.`approver_character_ref` = ?
                    AND `request`.`status` IN ('pending', 'approved')]], { characterId })
            query([[UPDATE `synex_group_creation_requests`
                SET `status` = 'rejected', `failure_code` = 'CHARACTER_DELETED',
                    `completed_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
                WHERE `status` IN ('pending', 'approved')
                    AND (`requested_by_ref` = ?
                        OR JSON_SEARCH(`request_json`, 'one', ?) IS NOT NULL)]],
                { characterId, characterId })
            query([[UPDATE `synex_group_creation_requests`
                SET `requested_by_ref` = CASE WHEN `requested_by_ref` = ?
                        THEN ? ELSE `requested_by_ref` END,
                    `request_json` = CASE
                        WHEN JSON_SEARCH(`request_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `request_json` END,
                    `version` = `version` + 1
                WHERE `requested_by_ref` = ?
                    OR JSON_SEARCH(`request_json`, 'one', ?) IS NOT NULL]],
                { characterId, anonymousRef, characterId, characterId, characterId })
            query([[UPDATE `synex_group_creation_approvals`
                SET `approver_character_ref` = ?
                WHERE `approver_character_ref` = ?]], { anonymousRef, characterId })
            query([[UPDATE `synex_group_membership_events` AS `event`
                SET `event`.`actor_ref` = CASE WHEN `event`.`actor_ref` = ? THEN ? ELSE `event`.`actor_ref` END,
                    `event`.`snapshot_json` = CASE
                        WHEN JSON_SEARCH(`event`.`snapshot_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `event`.`snapshot_json` END
                WHERE `event`.`actor_ref` = ?
                    OR JSON_SEARCH(`event`.`snapshot_json`, 'one', ?) IS NOT NULL]],
                { characterId, anonymousRef, characterId, characterId, characterId })
            query([[UPDATE `synex_group_membership_grades`
                SET `assigned_by_ref` = ? WHERE `assigned_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_membership_attributes`
                SET `updated_by_ref` = ? WHERE `updated_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_membership_transition_policies`
                SET `updated_by_ref` = ? WHERE `updated_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_primary_membership_events`
                SET `subject_ref` = CASE WHEN `subject_kind` = 'character'
                        AND `subject_ref` = ? THEN ? ELSE `subject_ref` END,
                    `actor_ref` = CASE WHEN `actor_ref` = ? THEN ? ELSE `actor_ref` END,
                    `snapshot_json` = CASE
                        WHEN JSON_SEARCH(`snapshot_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `snapshot_json` END
                WHERE (`subject_kind` = 'character' AND `subject_ref` = ?)
                    OR `actor_ref` = ?
                    OR JSON_SEARCH(`snapshot_json`, 'one', ?) IS NOT NULL]],
                { characterId, anonymousRef, characterId, anonymousRef,
                    characterId, characterId, characterId, characterId })
            query([[DELETE `primary_by_type`
                FROM `synex_group_primary_memberships_by_type` AS `primary_by_type`
                WHERE `primary_by_type`.`character_id` = ?]], { characterId })
            query([[DELETE `primary_membership`
                FROM `synex_group_primary_memberships` AS `primary_membership`
                WHERE `primary_membership`.`subject_kind` = 'character'
                    AND `primary_membership`.`subject_ref` = ?]], { characterId })
            query([[UPDATE `synex_group_membership_profiles`
                SET `character_id` = ?, `lifecycle_state` = 'ARCHIVED',
                    `joined_at` = COALESCE(`joined_at`, `created_at`),
                    `suspended_at` = NULL, `left_at` = CURRENT_TIMESTAMP(6),
                    `lifecycle_reason_code` = 'character_deleted',
                    `version` = `version` + 1
                WHERE `character_id` = ?]], { anonymousRef, characterId })
            query([[UPDATE `synex_group_memberships`
                SET `subject_ref` = ?, `status` = 'removed',
                    `version` = `version` + 1
                WHERE `subject_kind` = 'character' AND `subject_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_groups` SET `created_by_ref` = ? WHERE `created_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_hierarchy_edges`
                SET `created_by_ref` = ? WHERE `created_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_relationships`
                SET `created_by_ref` = ? WHERE `created_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_reporting_edges`
                SET `created_by_ref` = ? WHERE `created_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_membership_roles`
                SET `assigned_by_ref` = ? WHERE `assigned_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_duty_events`
                SET `actor_ref` = ? WHERE `actor_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_group_domain_history`
                SET `actor_ref` = CASE WHEN `actor_kind` = 'character' AND `actor_ref` = ?
                        THEN ? ELSE `actor_ref` END,
                    `before_json` = CASE
                        WHEN JSON_SEARCH(`before_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `before_json` END,
                    `after_json` = CASE
                        WHEN JSON_SEARCH(`after_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `after_json` END
                WHERE (`actor_kind` = 'character' AND `actor_ref` = ?)
                    OR JSON_SEARCH(`before_json`, 'one', ?) IS NOT NULL
                    OR JSON_SEARCH(`after_json`, 'one', ?) IS NOT NULL]],
                { characterId, anonymousRef, characterId, characterId,
                    characterId, characterId, characterId })
            query([[UPDATE `synex_group_domain_history_archive`
                SET `actor_ref` = CASE WHEN `actor_kind` = 'character' AND `actor_ref` = ?
                        THEN ? ELSE `actor_ref` END,
                    `before_json` = CASE
                        WHEN JSON_SEARCH(`before_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `before_json` END,
                    `after_json` = CASE
                        WHEN JSON_SEARCH(`after_json`, 'one', ?) IS NOT NULL
                        THEN JSON_OBJECT('redacted', 'character_deleted')
                        ELSE `after_json` END
                WHERE (`actor_kind` = 'character' AND `actor_ref` = ?)
                    OR JSON_SEARCH(`before_json`, 'one', ?) IS NOT NULL
                    OR JSON_SEARCH(`after_json`, 'one', ?) IS NOT NULL]],
                { characterId, anonymousRef, characterId, characterId,
                    characterId, characterId, characterId })
            query([[UPDATE `synex_group_outbox`
                SET `payload_json` = JSON_OBJECT('redacted', 'character_deleted'),
                    `state` = CASE WHEN `state` IN ('pending', 'publishing')
                        THEN 'dead' ELSE `state` END,
                    `locked_by` = NULL, `locked_until` = NULL
                WHERE JSON_SEARCH(`payload_json`, 'one', ?) IS NOT NULL]],
                { characterId })
            query([[INSERT INTO `synex_group_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.groups.character_anonymized', 1, ?)]],
                { eventId, anonymousRef, responseJson })
            query([[UPDATE `synex_group_character_deletions`
                SET `membership_count` = ?, `primary_count` = ?, `state` = 'completed',
                    `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `plan_id` = ? AND `anonymous_ref` = ? AND `state` = 'pending']],
                { #memberships, primaryCount, planId, anonymousRef })
            result = response
            return true
        end)
        if not committed then return nil, domainFailure or transactionError end
        invalidateCharacter(characterId)
        return result, nil
    end

    function port:getControlSummary()
        local overview = one([[SELECT
                (SELECT COUNT(*) FROM `synex_groups`) AS `groups`,
                (SELECT COUNT(*) FROM `synex_groups` WHERE `status` = 'active') AS `active_groups`,
                (SELECT COUNT(*) FROM `synex_group_memberships`) AS `memberships`,
                (SELECT COUNT(*) FROM `synex_group_membership_profiles`
                    WHERE `lifecycle_state` = 'ACTIVE') AS `active_memberships`,
                (SELECT COUNT(*) FROM `synex_group_grades` WHERE `status` = 'active') AS `active_grades`,
                (SELECT COUNT(*) FROM `synex_group_grade_capabilities`) AS `capability_rules`,
                (SELECT COUNT(*) FROM `synex_group_primary_memberships_by_type`)
                    AS `primary_memberships`]]) or {}
        local byStatus = many([[SELECT `status`, COUNT(*) AS `count`
            FROM `synex_groups` GROUP BY `status` ORDER BY `status` ASC LIMIT 8]])
        local byType = many([[SELECT `group_type`, COUNT(*) AS `count`
            FROM `synex_groups` GROUP BY `group_type` ORDER BY `count` DESC, `group_type` ASC LIMIT 16]])
        local membershipStatus = many([[SELECT `membership`.`subject_kind`,
                `profile`.`lifecycle_state` AS `status`, COUNT(*) AS `count`
            FROM `synex_group_memberships` AS `membership`
            INNER JOIN `synex_group_membership_profiles` AS `profile`
                ON `profile`.`membership_id` = `membership`.`id`
            GROUP BY `membership`.`subject_kind`, `profile`.`lifecycle_state`
            ORDER BY `membership`.`subject_kind`, `profile`.`lifecycle_state` LIMIT 16]])
        local largest = many([[SELECT `group`.`group_key`, `group`.`display_name`, `group`.`group_type`,
                COUNT(`profile`.`membership_id`) AS `active_memberships`, `model`.`model_version`
            FROM `synex_groups` AS `group`
            INNER JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
            LEFT JOIN `synex_group_memberships` AS `membership`
                ON `membership`.`group_id` = `group`.`id`
            LEFT JOIN `synex_group_membership_profiles` AS `profile`
                ON `profile`.`membership_id` = `membership`.`id`
                AND `profile`.`lifecycle_state` = 'ACTIVE'
            GROUP BY `group`.`id`, `group`.`group_key`, `group`.`display_name`, `group`.`group_type`, `model`.`model_version`
            ORDER BY COUNT(`profile`.`membership_id`) DESC, `group`.`group_key` ASC LIMIT 16]])
        return {
            overview = {
                groups = tonumber(overview.groups) or 0,
                activeGroups = tonumber(overview.active_groups) or 0,
                memberships = tonumber(overview.memberships) or 0,
                activeMemberships = tonumber(overview.active_memberships) or 0,
                activeGrades = tonumber(overview.active_grades) or 0,
                capabilityRules = tonumber(overview.capability_rules) or 0,
                primaryMemberships = tonumber(overview.primary_memberships) or 0,
            },
            groupsByStatus = byStatus,
            groupsByType = byType,
            membershipsByStatus = membershipStatus,
            largestGroups = largest,
        }, nil
    end
end
