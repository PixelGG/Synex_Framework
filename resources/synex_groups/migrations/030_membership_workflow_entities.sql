DROP PROCEDURE IF EXISTS `synex_groups_migrate_030_membership_workflow_entities`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_030_membership_workflow_entities`()
BEGIN
    DECLARE `v_enforced_metadata` TINYINT UNSIGNED DEFAULT 0;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_memberships', 'synex_group_membership_profiles',
                'synex_group_membership_events', 'synex_group_reporting_closure',
                'synex_group_invitations', 'synex_group_applications'
            ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 6 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 030 workflow prerequisite verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_invitations'
            AND `COLUMN_NAME` = 'membership_id'
    ) THEN
        ALTER TABLE `synex_group_invitations`
            ADD COLUMN `membership_id` BIGINT UNSIGNED NULL AFTER `character_id`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `COLUMN_NAME` = 'membership_id'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD COLUMN `membership_id` BIGINT UNSIGNED NULL AFTER `character_id`;
    END IF;

    UPDATE `synex_group_invitations` AS `invitation`
    INNER JOIN `synex_group_applications` AS `application`
        ON `application`.`group_id` = `invitation`.`group_id`
        AND `application`.`character_id` = `invitation`.`character_id`
        AND `application`.`status` IN ('submitted', 'reviewing')
        AND `application`.`created_at` >= `invitation`.`created_at`
    SET `invitation`.`status` = 'expired',
        `invitation`.`responded_at` = CURRENT_TIMESTAMP(6),
        `invitation`.`reason_code` = 'workflow_migration_conflict',
        `invitation`.`version` = `invitation`.`version` + 1
    WHERE `invitation`.`status` = 'pending';

    UPDATE `synex_group_applications` AS `application`
    INNER JOIN `synex_group_invitations` AS `invitation`
        ON `invitation`.`group_id` = `application`.`group_id`
        AND `invitation`.`character_id` = `application`.`character_id`
        AND `invitation`.`status` = 'pending'
        AND `invitation`.`created_at` > `application`.`created_at`
    SET `application`.`status` = 'expired',
        `application`.`reviewed_at` = CURRENT_TIMESTAMP(6),
        `application`.`review_reason_code` = 'workflow_migration_conflict',
        `application`.`version` = `application`.`version` + 1
    WHERE `application`.`status` IN ('submitted', 'reviewing');

    INSERT INTO `synex_group_memberships`
        (`public_id`, `group_id`, `subject_kind`, `subject_ref`, `role_key`,
         `status`, `version`, `created_at`, `updated_at`)
    SELECT CONCAT('group_member_', SUBSTRING(SHA2(CONCAT(
            'workflow:', `workflow`.`group_id`, ':', `workflow`.`character_id`), 256), 1, 28)),
        `workflow`.`group_id`, 'character', `workflow`.`character_id`, 'pending',
        'active', 1, `workflow`.`created_at`, CURRENT_TIMESTAMP(6)
    FROM (
        SELECT `source`.`group_id`, `source`.`character_id`,
            MIN(`source`.`created_at`) AS `created_at`
        FROM (
            SELECT `group_id`, `character_id`, `created_at`
            FROM `synex_group_invitations`
            UNION ALL
            SELECT `group_id`, `character_id`, `created_at`
            FROM `synex_group_applications`
        ) AS `source`
        GROUP BY `source`.`group_id`, `source`.`character_id`
    ) AS `workflow`
    LEFT JOIN `synex_group_memberships` AS `membership`
        ON `membership`.`group_id` = `workflow`.`group_id`
        AND `membership`.`subject_kind` = 'character'
        AND `membership`.`subject_ref` = `workflow`.`character_id`
    WHERE `membership`.`id` IS NULL;

    INSERT INTO `synex_group_membership_profiles`
        (`membership_id`, `group_id`, `character_id`, `lifecycle_state`, `visibility`,
         `joined_at`, `suspended_at`, `left_at`, `lifecycle_reason_code`, `version`,
         `created_at`, `updated_at`)
    SELECT `membership`.`id`, `membership`.`group_id`, `membership`.`subject_ref`,
        CASE
            WHEN EXISTS (
                SELECT 1 FROM `synex_group_applications` AS `application`
                WHERE `application`.`group_id` = `membership`.`group_id`
                    AND `application`.`character_id` = `membership`.`subject_ref`
                    AND `application`.`status` = 'reviewing'
            ) THEN 'UNDER_REVIEW'
            WHEN EXISTS (
                SELECT 1 FROM `synex_group_applications` AS `application`
                WHERE `application`.`group_id` = `membership`.`group_id`
                    AND `application`.`character_id` = `membership`.`subject_ref`
                    AND `application`.`status` = 'submitted'
            ) THEN 'APPLICANT'
            WHEN EXISTS (
                SELECT 1 FROM `synex_group_invitations` AS `invitation`
                WHERE `invitation`.`group_id` = `membership`.`group_id`
                    AND `invitation`.`character_id` = `membership`.`subject_ref`
                    AND `invitation`.`status` = 'pending'
            ) THEN 'INVITED'
            ELSE 'DRAFT'
        END,
        'hidden', NULL, NULL, NULL, 'workflow_entity_migrated', 1,
        `membership`.`created_at`, CURRENT_TIMESTAMP(6)
    FROM `synex_group_memberships` AS `membership`
    LEFT JOIN `synex_group_membership_profiles` AS `profile`
        ON `profile`.`membership_id` = `membership`.`id`
    WHERE `membership`.`subject_kind` = 'character'
        AND `profile`.`membership_id` IS NULL
        AND (EXISTS (
                SELECT 1 FROM `synex_group_invitations` AS `invitation`
                WHERE `invitation`.`group_id` = `membership`.`group_id`
                    AND `invitation`.`character_id` = `membership`.`subject_ref`
            ) OR EXISTS (
                SELECT 1 FROM `synex_group_applications` AS `application`
                WHERE `application`.`group_id` = `membership`.`group_id`
                    AND `application`.`character_id` = `membership`.`subject_ref`
            ));

    INSERT INTO `synex_group_reporting_closure`
        (`manager_membership_id`, `report_membership_id`, `depth`)
    SELECT `profile`.`membership_id`, `profile`.`membership_id`, 0
    FROM `synex_group_membership_profiles` AS `profile`
    LEFT JOIN `synex_group_reporting_closure` AS `closure`
        ON `closure`.`manager_membership_id` = `profile`.`membership_id`
        AND `closure`.`report_membership_id` = `profile`.`membership_id`
    WHERE `closure`.`manager_membership_id` IS NULL;

    INSERT INTO `synex_group_membership_events`
        (`event_id`, `membership_id`, `membership_version`, `event_type`,
         `actor_ref`, `snapshot_json`, `occurred_at`)
    SELECT CONCAT('group_mevent_', SUBSTRING(SHA2(CONCAT(
            'workflow:', `membership`.`public_id`), 256), 1, 32)),
        `membership`.`id`, `membership`.`version`, 'added', NULL,
        JSON_OBJECT(
            'membership_id', `membership`.`public_id`,
            'group_id', `group_record`.`public_id`,
            'character_id', `profile`.`character_id`,
            'lifecycle_state', `profile`.`lifecycle_state`,
            'version', `membership`.`version`
        ), `membership`.`created_at`
    FROM `synex_group_memberships` AS `membership`
    INNER JOIN `synex_group_membership_profiles` AS `profile`
        ON `profile`.`membership_id` = `membership`.`id`
    INNER JOIN `synex_groups` AS `group_record`
        ON `group_record`.`id` = `membership`.`group_id`
    LEFT JOIN `synex_group_membership_events` AS `membership_event`
        ON `membership_event`.`membership_id` = `membership`.`id`
    WHERE `membership_event`.`membership_id` IS NULL
        AND (EXISTS (
                SELECT 1 FROM `synex_group_invitations` AS `invitation`
                WHERE `invitation`.`group_id` = `membership`.`group_id`
                    AND `invitation`.`character_id` = `profile`.`character_id`
            ) OR EXISTS (
                SELECT 1 FROM `synex_group_applications` AS `application`
                WHERE `application`.`group_id` = `membership`.`group_id`
                    AND `application`.`character_id` = `profile`.`character_id`
            ));

    UPDATE `synex_group_invitations` AS `invitation`
    INNER JOIN `synex_group_memberships` AS `membership`
        ON `membership`.`group_id` = `invitation`.`group_id`
        AND `membership`.`subject_kind` = 'character'
        AND `membership`.`subject_ref` = `invitation`.`character_id`
    SET `invitation`.`membership_id` = `membership`.`id`
    WHERE `invitation`.`membership_id` IS NULL;

    UPDATE `synex_group_applications` AS `application`
    INNER JOIN `synex_group_memberships` AS `membership`
        ON `membership`.`group_id` = `application`.`group_id`
        AND `membership`.`subject_kind` = 'character'
        AND `membership`.`subject_ref` = `application`.`character_id`
    SET `application`.`membership_id` = `membership`.`id`
    WHERE `application`.`membership_id` IS NULL;

    ALTER TABLE `synex_group_invitations`
        MODIFY COLUMN `membership_id` BIGINT UNSIGNED NOT NULL;
    ALTER TABLE `synex_group_applications`
        MODIFY COLUMN `membership_id` BIGINT UNSIGNED NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_invitations'
            AND `INDEX_NAME` = 'idx_group_invitations_membership'
    ) THEN
        ALTER TABLE `synex_group_invitations`
            ADD KEY `idx_group_invitations_membership`
                (`membership_id`, `status`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `INDEX_NAME` = 'idx_group_applications_membership'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD KEY `idx_group_applications_membership`
                (`membership_id`, `status`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_invitations'
            AND `CONSTRAINT_NAME` = 'fk_group_invitations_membership'
            AND `CONSTRAINT_TYPE` = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE `synex_group_invitations`
            ADD CONSTRAINT `fk_group_invitations_membership`
                FOREIGN KEY (`membership_id`)
                REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `CONSTRAINT_NAME` = 'fk_group_applications_membership'
            AND `CONSTRAINT_TYPE` = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD CONSTRAINT `fk_group_applications_membership`
                FOREIGN KEY (`membership_id`)
                REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_events'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_events_type_v2'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_membership_events`
            ADD CONSTRAINT `chk_group_membership_events_type_v2`
                CHECK (`event_type` IN (
                    'added', 'role_changed', 'suspended', 'removed',
                    'transitioned', 'grade_changed', 'visibility_changed'
                ));
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_events'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_events_type'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_membership_events`
            DROP CONSTRAINT `chk_group_membership_events_type`;
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_invitations'
                    AND `COLUMN_NAME` = 'membership_id'
                    AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_applications'
                    AND `COLUMN_NAME` = 'membership_id'
                    AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO'))
    ) <> 2 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_invitations'
                    AND `INDEX_NAME` = 'idx_group_invitations_membership')
                OR (`TABLE_NAME` = 'synex_group_applications'
                    AND `INDEX_NAME` = 'idx_group_applications_membership'))
    ) <> 6 OR (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_invitations'
                    AND `CONSTRAINT_NAME` = 'fk_group_invitations_membership'
                    AND `COLUMN_NAME` = 'membership_id')
                OR (`TABLE_NAME` = 'synex_group_applications'
                    AND `CONSTRAINT_NAME` = 'fk_group_applications_membership'
                    AND `COLUMN_NAME` = 'membership_id'))
            AND `REFERENCED_TABLE_NAME` = 'synex_group_memberships'
            AND `REFERENCED_COLUMN_NAME` = 'id'
    ) <> 2 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_events'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_events_type_v2'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_group_membership_events_type_v2'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                    CHAR(9), ''), CHAR(10), ''), CHAR(13), ''),
                '_utf8mb4', ''), '_utf8mb3', ''), '_utf8', ''),
                '_ascii', ''), '_latin1', '')
                = 'event_typein''added'',''role_changed'',''suspended'',''removed'',''transitioned'',''grade_changed'',''visibility_changed'''
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_invitations` AS `invitation`
        INNER JOIN `synex_group_membership_profiles` AS `profile`
            ON `profile`.`membership_id` = `invitation`.`membership_id`
        WHERE `profile`.`group_id` <> `invitation`.`group_id`
            OR `profile`.`character_id` <> `invitation`.`character_id`
            OR (`invitation`.`status` = 'pending'
                AND (`profile`.`lifecycle_state` <> 'INVITED'
                    OR `profile`.`visibility` <> 'hidden'
                    OR `profile`.`joined_at` IS NOT NULL
                    OR `profile`.`suspended_at` IS NOT NULL
                    OR `profile`.`left_at` IS NOT NULL))
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_applications` AS `application`
        INNER JOIN `synex_group_membership_profiles` AS `profile`
            ON `profile`.`membership_id` = `application`.`membership_id`
        WHERE `profile`.`group_id` <> `application`.`group_id`
            OR `profile`.`character_id` <> `application`.`character_id`
            OR (`application`.`status` = 'submitted'
                AND (`profile`.`lifecycle_state` <> 'APPLICANT'
                    OR `profile`.`visibility` <> 'hidden'
                    OR `profile`.`joined_at` IS NOT NULL
                    OR `profile`.`suspended_at` IS NOT NULL
                    OR `profile`.`left_at` IS NOT NULL))
            OR (`application`.`status` = 'reviewing'
                AND (`profile`.`lifecycle_state` <> 'UNDER_REVIEW'
                    OR `profile`.`visibility` <> 'hidden'
                    OR `profile`.`joined_at` IS NOT NULL
                    OR `profile`.`suspended_at` IS NOT NULL
                    OR `profile`.`left_at` IS NOT NULL))
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_invitations` AS `invitation`
        INNER JOIN `synex_group_applications` AS `application`
            ON `application`.`group_id` = `invitation`.`group_id`
            AND `application`.`character_id` = `invitation`.`character_id`
        WHERE `invitation`.`status` = 'pending'
            AND `application`.`status` IN ('submitted', 'reviewing')
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 030 workflow entity verification failed';
    END IF;

    SELECT COUNT(*) INTO `v_enforced_metadata`
    FROM `information_schema`.`COLUMNS`
    WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
        AND UPPER(`TABLE_NAME`) = 'TABLE_CONSTRAINTS'
        AND UPPER(`COLUMN_NAME`) = 'ENFORCED';
    IF `v_enforced_metadata` > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 030 check enforcement metadata is ambiguous';
    END IF;
    IF `v_enforced_metadata` = 1 THEN
        SET @`synex_groups_migrate_030_enforced_checks` = NULL;
        SET @`synex_groups_migrate_030_enforced_sql` =
            'SELECT COUNT(*) INTO @synex_groups_migrate_030_enforced_checks '
            'FROM information_schema.TABLE_CONSTRAINTS '
            'WHERE CONSTRAINT_SCHEMA = DATABASE() '
            'AND TABLE_NAME = ''synex_group_membership_events'' '
            'AND CONSTRAINT_NAME = ''chk_group_membership_events_type_v2'' '
            'AND CONSTRAINT_TYPE = ''CHECK'' '
            'AND UPPER(COALESCE(ENFORCED, ''NO'')) = ''YES''';
        PREPARE `synex_groups_migrate_030_enforced_statement`
            FROM @`synex_groups_migrate_030_enforced_sql`;
        EXECUTE `synex_groups_migrate_030_enforced_statement`;
        DEALLOCATE PREPARE `synex_groups_migrate_030_enforced_statement`;
        IF COALESCE(@`synex_groups_migrate_030_enforced_checks`, 0) <> 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'synex groups migration 030 membership event check is not enforced';
        END IF;
        SET @`synex_groups_migrate_030_enforced_checks` = NULL;
        SET @`synex_groups_migrate_030_enforced_sql` = NULL;
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_030_membership_workflow_entities`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_030_membership_workflow_entities`;
