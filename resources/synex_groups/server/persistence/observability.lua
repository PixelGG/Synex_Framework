return function(port, context)
    local domainError = context.domainError
    local jsonEncode = context.jsonEncode
    local many = context.many
    local one = context.one
    local random = context.random
    local uuidV4 = context.uuidV4
    local withTransaction = context.withTransaction

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
            LEFT JOIN `synex_group_primary_memberships` AS `primary`
                ON `primary`.`subject_kind` = `membership`.`subject_kind`
                AND `primary`.`subject_ref` = `membership`.`subject_ref`
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
                (SELECT COUNT(*) FROM `synex_group_memberships`
                    WHERE `subject_kind` = 'character' AND `subject_ref` = ? AND `status` = 'active')
                    AS `active_membership_count`,
                (SELECT COUNT(*) FROM `synex_group_primary_memberships`
                    WHERE `subject_kind` = 'character' AND `subject_ref` = ?) AS `primary_count`]],
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
            local primary = query([[SELECT `membership_id` FROM `synex_group_primary_memberships`
                WHERE `subject_kind` = 'character' AND `subject_ref` = ? FOR UPDATE]], { characterId }) or {}
            local response = {
                anonymousRef = anonymousRef,
                memberships = #memberships,
                primaryMemberships = #primary,
                state = 'completed',
            }
            local responseJson = jsonEncode(response)

            query([[UPDATE `synex_group_read_model_versions` AS `model`
                INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`group_id` = `model`.`group_id`
                SET `model`.`model_version` = `model`.`model_version` + 1,
                    `model`.`invalidated_at` = CURRENT_TIMESTAMP(6)
                WHERE `membership`.`subject_kind` = 'character' AND `membership`.`subject_ref` = ?]],
                { characterId })
            query([[UPDATE `synex_group_membership_events` AS `event`
                INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`id` = `event`.`membership_id`
                SET `event`.`actor_ref` = CASE WHEN `event`.`actor_ref` = ? THEN ? ELSE `event`.`actor_ref` END,
                    `event`.`snapshot_json` = JSON_SET(`event`.`snapshot_json`, '$.subject_id', ?)
                WHERE `membership`.`subject_kind` = 'character' AND `membership`.`subject_ref` = ?]],
                { characterId, anonymousRef, anonymousRef, characterId })
            query([[UPDATE `synex_group_membership_grades` AS `assigned`
                INNER JOIN `synex_group_memberships` AS `membership` ON `membership`.`id` = `assigned`.`membership_id`
                SET `assigned`.`assigned_by_ref` = CASE WHEN `assigned`.`assigned_by_ref` = ? THEN ?
                    ELSE `assigned`.`assigned_by_ref` END
                WHERE `membership`.`subject_kind` = 'character' AND `membership`.`subject_ref` = ?]],
                { characterId, anonymousRef, characterId })
            query([[UPDATE `synex_group_primary_membership_events`
                SET `subject_ref` = ?,
                    `actor_ref` = CASE WHEN `actor_ref` = ? THEN ? ELSE `actor_ref` END,
                    `snapshot_json` = JSON_SET(`snapshot_json`, '$.subject_id', ?)
                WHERE `subject_kind` = 'character' AND `subject_ref` = ?]],
                { anonymousRef, characterId, anonymousRef, anonymousRef, characterId })
            query([[UPDATE `synex_group_primary_memberships`
                SET `subject_ref` = ?,
                    `assigned_by_ref` = CASE WHEN `assigned_by_ref` = ? THEN ? ELSE `assigned_by_ref` END
                WHERE `subject_kind` = 'character' AND `subject_ref` = ?]],
                { anonymousRef, characterId, anonymousRef, characterId })
            query([[UPDATE `synex_group_memberships`
                SET `subject_ref` = ?, `version` = `version` + 1
                WHERE `subject_kind` = 'character' AND `subject_ref` = ?]],
                { anonymousRef, characterId })
            query([[UPDATE `synex_groups` SET `created_by_ref` = ? WHERE `created_by_ref` = ?]],
                { anonymousRef, characterId })
            query([[INSERT INTO `synex_group_outbox`
                (`event_id`, `aggregate_id`, `event_type`, `schema_version`, `payload_json`)
                VALUES (?, ?, 'synex.groups.character_anonymized', 1, ?)]],
                { eventId, anonymousRef, responseJson })
            query([[UPDATE `synex_group_character_deletions`
                SET `membership_count` = ?, `primary_count` = ?, `state` = 'completed',
                    `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `plan_id` = ? AND `anonymous_ref` = ? AND `state` = 'pending']],
                { #memberships, #primary, planId, anonymousRef })
            result = response
            return true
        end)
        if not committed then return nil, domainFailure or transactionError end
        return result, nil
    end

    function port:getControlSummary()
        local overview = one([[SELECT
                (SELECT COUNT(*) FROM `synex_groups`) AS `groups`,
                (SELECT COUNT(*) FROM `synex_groups` WHERE `status` = 'active') AS `active_groups`,
                (SELECT COUNT(*) FROM `synex_group_memberships`) AS `memberships`,
                (SELECT COUNT(*) FROM `synex_group_memberships` WHERE `status` = 'active') AS `active_memberships`,
                (SELECT COUNT(*) FROM `synex_group_grades` WHERE `status` = 'active') AS `active_grades`,
                (SELECT COUNT(*) FROM `synex_group_grade_capabilities`) AS `capability_rules`,
                (SELECT COUNT(*) FROM `synex_group_primary_memberships`) AS `primary_memberships`]]) or {}
        local byStatus = many([[SELECT `status`, COUNT(*) AS `count`
            FROM `synex_groups` GROUP BY `status` ORDER BY `status` ASC LIMIT 8]])
        local byType = many([[SELECT `group_type`, COUNT(*) AS `count`
            FROM `synex_groups` GROUP BY `group_type` ORDER BY `count` DESC, `group_type` ASC LIMIT 16]])
        local membershipStatus = many([[SELECT `subject_kind`, `status`, COUNT(*) AS `count`
            FROM `synex_group_memberships`
            GROUP BY `subject_kind`, `status` ORDER BY `subject_kind`, `status` LIMIT 16]])
        local largest = many([[SELECT `group`.`group_key`, `group`.`display_name`, `group`.`group_type`,
                COUNT(`membership`.`id`) AS `active_memberships`, `model`.`model_version`
            FROM `synex_groups` AS `group`
            INNER JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
            LEFT JOIN `synex_group_memberships` AS `membership` ON `membership`.`group_id` = `group`.`id`
                AND `membership`.`status` = 'active'
            GROUP BY `group`.`id`, `group`.`group_key`, `group`.`display_name`, `group`.`group_type`, `model`.`model_version`
            ORDER BY COUNT(`membership`.`id`) DESC, `group`.`group_key` ASC LIMIT 16]])
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
