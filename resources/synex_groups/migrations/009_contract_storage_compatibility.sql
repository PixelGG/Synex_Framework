CREATE TABLE IF NOT EXISTS `synex_group_membership_states` (
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(64) NOT NULL,
    `terminal_state` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`state_key`),
    KEY `idx_group_membership_states_owner` (`owner_resource`, `status`, `state_key`),
    CONSTRAINT `chk_group_membership_states_key`
        CHECK (`state_key` REGEXP '^[A-Z][A-Z0-9_]{1,31}$'),
    CONSTRAINT `chk_group_membership_states_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_group_membership_states_terminal` CHECK (`terminal_state` IN (0, 1)),
    CONSTRAINT `chk_group_membership_states_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_membership_states_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_type_membership_states` (
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `sort_order` SMALLINT UNSIGNED NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_type_id`, `state_key`),
    UNIQUE KEY `uq_group_type_membership_state_order` (`group_type_id`, `sort_order`),
    KEY `idx_group_type_membership_states_state` (`state_key`, `group_type_id`),
    CONSTRAINT `fk_group_type_membership_states_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_type_membership_states_state`
        FOREIGN KEY (`state_key`) REFERENCES `synex_group_membership_states` (`state_key`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_type_membership_states_order` CHECK (`sort_order` < 16)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_type_duty_states` (
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_type_id`, `state_key`),
    KEY `idx_group_type_duty_states_state` (`state_key`, `group_type_id`),
    CONSTRAINT `fk_group_type_duty_states_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_type_duty_states_state`
        FOREIGN KEY (`state_key`) REFERENCES `synex_group_duty_states` (`state_key`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_invitation_roles` (
    `invitation_id` BIGINT UNSIGNED NOT NULL,
    `role_id` BIGINT UNSIGNED NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`invitation_id`, `role_id`),
    KEY `idx_group_invitation_roles_role` (`role_id`, `invitation_id`),
    CONSTRAINT `fk_group_invitation_roles_invitation`
        FOREIGN KEY (`invitation_id`) REFERENCES `synex_group_invitations` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_invitation_roles_role`
        FOREIGN KEY (`role_id`) REFERENCES `synex_group_roles` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_009_contract_storage_compatibility`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_009_contract_storage_compatibility`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` IN (
            'synex_group_membership_states',
            'synex_group_type_membership_states',
            'synex_group_type_duty_states',
            'synex_group_invitation_roles'
        ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 4 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 compatibility table verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'state_key'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 32
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'display_name'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 64
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'terminal_state'
                AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'owner_resource'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 64
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'status'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 16
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states' AND `COLUMN_NAME` = 'version'
                AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_membership_states'
                AND `COLUMN_NAME` IN ('created_at', 'updated_at') AND `DATA_TYPE` = 'datetime'
                AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_membership_states' AND `COLUMN_NAME` = 'group_type_id'
                AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_membership_states' AND `COLUMN_NAME` = 'state_key'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 32
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_membership_states' AND `COLUMN_NAME` = 'sort_order'
                AND `DATA_TYPE` = 'smallint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_membership_states' AND `COLUMN_NAME` = 'created_at'
                AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_duty_states' AND `COLUMN_NAME` = 'group_type_id'
                AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_duty_states' AND `COLUMN_NAME` = 'state_key'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 32
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_type_duty_states' AND `COLUMN_NAME` = 'created_at'
                AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_invitation_roles'
                AND `COLUMN_NAME` IN ('invitation_id', 'role_id') AND `DATA_TYPE` = 'bigint'
                AND `COLUMN_TYPE` LIKE '%unsigned%' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_invitation_roles' AND `COLUMN_NAME` = 'created_at'
                AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO')
        )
    ) <> 18 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 compatibility column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND (
                (`TABLE_NAME` = 'synex_group_membership_states' AND `INDEX_NAME` = 'PRIMARY'
                    AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state_key')
                OR (`TABLE_NAME` = 'synex_group_membership_states'
                    AND `INDEX_NAME` = 'idx_group_membership_states_owner' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'owner_resource')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'status')
                        OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'state_key')))
                OR (`TABLE_NAME` = 'synex_group_type_membership_states' AND `INDEX_NAME` = 'PRIMARY'
                    AND `NON_UNIQUE` = 0 AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'group_type_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'state_key')))
                OR (`TABLE_NAME` = 'synex_group_type_membership_states'
                    AND `INDEX_NAME` = 'uq_group_type_membership_state_order' AND `NON_UNIQUE` = 0
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'group_type_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'sort_order')))
                OR (`TABLE_NAME` = 'synex_group_type_membership_states'
                    AND `INDEX_NAME` = 'idx_group_type_membership_states_state' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state_key')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'group_type_id')))
                OR (`TABLE_NAME` = 'synex_group_type_duty_states' AND `INDEX_NAME` = 'PRIMARY'
                    AND `NON_UNIQUE` = 0 AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'group_type_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'state_key')))
                OR (`TABLE_NAME` = 'synex_group_type_duty_states'
                    AND `INDEX_NAME` = 'idx_group_type_duty_states_state' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state_key')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'group_type_id')))
                OR (`TABLE_NAME` = 'synex_group_invitation_roles' AND `INDEX_NAME` = 'PRIMARY'
                    AND `NON_UNIQUE` = 0 AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'invitation_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'role_id')))
                OR (`TABLE_NAME` = 'synex_group_invitation_roles'
                    AND `INDEX_NAME` = 'idx_group_invitation_roles_role' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'role_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'invitation_id')))
            )
    ) <> 18 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            (`TABLE_NAME` = 'synex_group_membership_states'
                AND `INDEX_NAME` = 'idx_group_membership_states_owner' AND `SEQ_IN_INDEX` > 3)
            OR (`TABLE_NAME` = 'synex_group_membership_states'
                AND `INDEX_NAME` = 'PRIMARY' AND `SEQ_IN_INDEX` > 1)
            OR (`TABLE_NAME` = 'synex_group_type_membership_states'
                AND `INDEX_NAME` IN ('PRIMARY', 'uq_group_type_membership_state_order',
                    'idx_group_type_membership_states_state') AND `SEQ_IN_INDEX` > 2)
            OR (`TABLE_NAME` = 'synex_group_type_duty_states'
                AND `INDEX_NAME` IN ('PRIMARY', 'idx_group_type_duty_states_state')
                AND `SEQ_IN_INDEX` > 2)
            OR (`TABLE_NAME` = 'synex_group_invitation_roles'
                AND `INDEX_NAME` IN ('PRIMARY', 'idx_group_invitation_roles_role')
                AND `SEQ_IN_INDEX` > 2)
        )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 compatibility index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE` AS `usage`
        INNER JOIN `information_schema`.`REFERENTIAL_CONSTRAINTS` AS `reference`
            ON `reference`.`CONSTRAINT_SCHEMA` = `usage`.`CONSTRAINT_SCHEMA`
            AND `reference`.`CONSTRAINT_NAME` = `usage`.`CONSTRAINT_NAME`
        WHERE `usage`.`CONSTRAINT_SCHEMA` = DATABASE() AND `reference`.`DELETE_RULE` = 'RESTRICT'
            AND (
                (`usage`.`TABLE_NAME` = 'synex_group_type_membership_states'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_type_membership_states_type'
                    AND `usage`.`COLUMN_NAME` = 'group_type_id'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_types'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'id')
                OR (`usage`.`TABLE_NAME` = 'synex_group_type_membership_states'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_type_membership_states_state'
                    AND `usage`.`COLUMN_NAME` = 'state_key'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_membership_states'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'state_key')
                OR (`usage`.`TABLE_NAME` = 'synex_group_type_duty_states'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_type_duty_states_type'
                    AND `usage`.`COLUMN_NAME` = 'group_type_id'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_types'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'id')
                OR (`usage`.`TABLE_NAME` = 'synex_group_type_duty_states'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_type_duty_states_state'
                    AND `usage`.`COLUMN_NAME` = 'state_key'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_duty_states'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'state_key')
                OR (`usage`.`TABLE_NAME` = 'synex_group_invitation_roles'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_invitation_roles_invitation'
                    AND `usage`.`COLUMN_NAME` = 'invitation_id'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_invitations'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'id')
                OR (`usage`.`TABLE_NAME` = 'synex_group_invitation_roles'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_invitation_roles_role'
                    AND `usage`.`COLUMN_NAME` = 'role_id'
                    AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_roles'
                    AND `usage`.`REFERENCED_COLUMN_NAME` = 'id')
            )
    ) <> 6 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `CONSTRAINT_TYPE` = 'CHECK' AND (
            (`TABLE_NAME` = 'synex_group_membership_states' AND `CONSTRAINT_NAME` IN (
                'chk_group_membership_states_key', 'chk_group_membership_states_owner',
                'chk_group_membership_states_terminal', 'chk_group_membership_states_status',
                'chk_group_membership_states_version'))
            OR (`TABLE_NAME` = 'synex_group_type_membership_states'
                AND `CONSTRAINT_NAME` = 'chk_group_type_membership_states_order')
        )
    ) <> 6 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 compatibility constraint verification failed';
    END IF;

    ALTER TABLE `synex_group_types`
        MODIFY COLUMN `membership_limit` INT UNSIGNED NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'schema_version'
    ) THEN
        ALTER TABLE `synex_group_types` ADD COLUMN `schema_version` INT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'dynamic_creation'
    ) THEN
        ALTER TABLE `synex_group_types` ADD COLUMN `dynamic_creation` TINYINT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_types` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;

    UPDATE `synex_group_types`
    SET `schema_version` = COALESCE(`schema_version`, 1),
        `dynamic_creation` = COALESCE(
            `dynamic_creation`, CASE WHEN `creation_mode` = 'dynamic' THEN 1 ELSE 0 END),
        `metadata_json` = COALESCE(`metadata_json`, '{}')
    WHERE `schema_version` IS NULL OR `dynamic_creation` IS NULL OR `metadata_json` IS NULL;

    ALTER TABLE `synex_group_types`
        MODIFY COLUMN `schema_version` INT UNSIGNED NOT NULL,
        MODIFY COLUMN `dynamic_creation` TINYINT UNSIGNED NOT NULL,
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_schema_version'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_schema_version` CHECK (`schema_version` > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_dynamic_creation'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_dynamic_creation`
                CHECK ((`dynamic_creation` = 1 AND `creation_mode` = 'dynamic')
                    OR (`dynamic_creation` = 0 AND `creation_mode` IN ('static', 'legacy')));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_membership_limit'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_membership_limit`
                CHECK (`membership_limit` IS NULL OR `membership_limit` BETWEEN 1 AND 100000);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_metadata_json` CHECK (JSON_VALID(`metadata_json`));
    END IF;

    INSERT INTO `synex_group_membership_states`
        (`state_key`, `display_name`, `terminal_state`, `owner_resource`, `status`, `version`)
    SELECT `seed`.`state_key`, `seed`.`display_name`, `seed`.`terminal_state`,
        'synex_groups', 'active', 1
    FROM (
        SELECT 'DRAFT' AS `state_key`, 'Draft' AS `display_name`, 0 AS `terminal_state`
        UNION ALL SELECT 'INVITED', 'Invited', 0
        UNION ALL SELECT 'APPLICANT', 'Applicant', 0
        UNION ALL SELECT 'UNDER_REVIEW', 'Under Review', 0
        UNION ALL SELECT 'APPROVED', 'Approved', 0
        UNION ALL SELECT 'PROBATION', 'Probation', 0
        UNION ALL SELECT 'ACTIVE', 'Active', 0
        UNION ALL SELECT 'SUSPENDED', 'Suspended', 0
        UNION ALL SELECT 'LEAVE', 'Leave', 0
        UNION ALL SELECT 'INACTIVE', 'Inactive', 0
        UNION ALL SELECT 'TERMINATED', 'Terminated', 1
        UNION ALL SELECT 'BANNED', 'Banned', 1
        UNION ALL SELECT 'LEFT', 'Left', 1
        UNION ALL SELECT 'ARCHIVED', 'Archived', 1
    ) AS `seed`
    LEFT JOIN `synex_group_membership_states` AS `existing`
        ON `existing`.`state_key` = `seed`.`state_key`
    WHERE `existing`.`state_key` IS NULL;

    UPDATE `synex_group_type_membership_states`
    SET `sort_order` = 13
    WHERE `state_key` = 'ARCHIVED' AND `sort_order` = 7;
    UPDATE `synex_group_type_membership_states`
    SET `sort_order` = 12
    WHERE `state_key` = 'LEFT' AND `sort_order` = 6;
    UPDATE `synex_group_type_membership_states`
    SET `sort_order` = 10
    WHERE `state_key` = 'TERMINATED' AND `sort_order` = 5;
    UPDATE `synex_group_type_membership_states`
    SET `sort_order` = 7
    WHERE `state_key` = 'SUSPENDED' AND `sort_order` = 4;
    UPDATE `synex_group_type_membership_states`
    SET `sort_order` = 6
    WHERE `state_key` = 'ACTIVE' AND `sort_order` = 3;

    INSERT INTO `synex_group_type_membership_states`
        (`group_type_id`, `state_key`, `sort_order`, `created_at`)
    SELECT `group_type`.`id`, `state`.`state_key`,
        CASE `state`.`state_key`
            WHEN 'DRAFT' THEN 0 WHEN 'INVITED' THEN 1 WHEN 'APPLICANT' THEN 2
            WHEN 'UNDER_REVIEW' THEN 3 WHEN 'APPROVED' THEN 4 WHEN 'PROBATION' THEN 5
            WHEN 'ACTIVE' THEN 6 WHEN 'SUSPENDED' THEN 7 WHEN 'LEAVE' THEN 8
            WHEN 'INACTIVE' THEN 9 WHEN 'TERMINATED' THEN 10 WHEN 'BANNED' THEN 11
            WHEN 'LEFT' THEN 12 WHEN 'ARCHIVED' THEN 13 ELSE 15
        END,
        `group_type`.`created_at`
    FROM `synex_group_types` AS `group_type`
    CROSS JOIN `synex_group_membership_states` AS `state`
    LEFT JOIN `synex_group_type_membership_states` AS `allowed`
        ON `allowed`.`group_type_id` = `group_type`.`id`
        AND `allowed`.`state_key` = `state`.`state_key`
    WHERE `state`.`status` = 'active' AND `allowed`.`group_type_id` IS NULL;

    INSERT INTO `synex_group_type_duty_states`
        (`group_type_id`, `state_key`, `created_at`)
    SELECT `group_type`.`id`, `state`.`state_key`, `group_type`.`created_at`
    FROM `synex_group_types` AS `group_type`
    CROSS JOIN `synex_group_duty_states` AS `state`
    LEFT JOIN `synex_group_type_duty_states` AS `allowed`
        ON `allowed`.`group_type_id` = `group_type`.`id`
        AND `allowed`.`state_key` = `state`.`state_key`
    WHERE `state`.`status` = 'active' AND `allowed`.`group_type_id` IS NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `COLUMN_NAME` = 'name'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles` ADD COLUMN `name` VARCHAR(96) NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `COLUMN_NAME` = 'label'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles` ADD COLUMN `label` VARCHAR(96) NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `COLUMN_NAME` = 'description'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles` ADD COLUMN `description` VARCHAR(1024) NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `COLUMN_NAME` = 'dynamic'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles` ADD COLUMN `dynamic` TINYINT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;

    UPDATE `synex_group_organization_profiles` AS `profile`
    INNER JOIN `synex_groups` AS `group_record` ON `group_record`.`id` = `profile`.`group_id`
    SET `profile`.`name` = COALESCE(
            `profile`.`name`, CASE WHEN CHAR_LENGTH(`group_record`.`display_name`) > 0
                THEN `group_record`.`display_name` ELSE `group_record`.`group_key` END),
        `profile`.`label` = COALESCE(
            `profile`.`label`, CASE WHEN CHAR_LENGTH(`group_record`.`display_name`) > 0
                THEN `group_record`.`display_name` ELSE `group_record`.`group_key` END),
        `profile`.`dynamic` = COALESCE(
            `profile`.`dynamic`, CASE WHEN `profile`.`creation_source` = 'dynamic' THEN 1 ELSE 0 END),
        `profile`.`metadata_json` = COALESCE(`profile`.`metadata_json`, `group_record`.`metadata_json`)
    WHERE `profile`.`name` IS NULL OR `profile`.`label` IS NULL
        OR `profile`.`dynamic` IS NULL OR `profile`.`metadata_json` IS NULL;

    ALTER TABLE `synex_group_organization_profiles`
        MODIFY COLUMN `name` VARCHAR(96) NOT NULL,
        MODIFY COLUMN `label` VARCHAR(96) NOT NULL,
        MODIFY COLUMN `description` VARCHAR(1024) NULL,
        MODIFY COLUMN `dynamic` TINYINT UNSIGNED NOT NULL,
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_profiles_name_label'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            ADD CONSTRAINT `chk_group_profiles_name_label`
                CHECK (CHAR_LENGTH(`name`) BETWEEN 1 AND 96 AND CHAR_LENGTH(`label`) BETWEEN 1 AND 96);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_profiles_description'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            ADD CONSTRAINT `chk_group_profiles_description`
                CHECK (`description` IS NULL OR CHAR_LENGTH(`description`) <= 1024);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_profiles_dynamic'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            ADD CONSTRAINT `chk_group_profiles_dynamic` CHECK (`dynamic` IN (0, 1));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_profiles_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            ADD CONSTRAINT `chk_group_profiles_metadata_json` CHECK (JSON_VALID(`metadata_json`));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relationships'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_relationships` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;
    UPDATE `synex_group_relationships`
    SET `metadata_json` = '{}'
    WHERE `metadata_json` IS NULL;
    ALTER TABLE `synex_group_relationships`
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relationships'
            AND `CONSTRAINT_NAME` = 'chk_group_relationships_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_relationships`
            ADD CONSTRAINT `chk_group_relationships_metadata_json` CHECK (JSON_VALID(`metadata_json`));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_applications'
            AND `COLUMN_NAME` = 'schema_version'
    ) THEN
        ALTER TABLE `synex_group_applications` ADD COLUMN `schema_version` INT UNSIGNED NULL;
    END IF;
    UPDATE `synex_group_applications`
    SET `schema_version` = 1
    WHERE `schema_version` IS NULL;
    ALTER TABLE `synex_group_applications`
        MODIFY COLUMN `schema_version` INT UNSIGNED NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_applications'
            AND `CONSTRAINT_NAME` = 'chk_group_applications_schema_version'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD CONSTRAINT `chk_group_applications_schema_version` CHECK (`schema_version` > 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_sessions'
            AND `COLUMN_NAME` = 'assignment_id'
    ) THEN
        ALTER TABLE `synex_group_duty_sessions` ADD COLUMN `assignment_id` BIGINT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_sessions'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_duty_sessions` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;
    UPDATE `synex_group_duty_sessions`
    SET `metadata_json` = '{}'
    WHERE `metadata_json` IS NULL;
    ALTER TABLE `synex_group_duty_sessions`
        MODIFY COLUMN `assignment_id` BIGINT UNSIGNED NULL,
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_sessions'
            AND `INDEX_NAME` = 'idx_group_duty_sessions_assignment'
    ) THEN
        ALTER TABLE `synex_group_duty_sessions`
            ADD KEY `idx_group_duty_sessions_assignment` (`assignment_id`, `status`, `id`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_sessions'
            AND `CONSTRAINT_NAME` = 'fk_group_duty_sessions_assignment'
    ) THEN
        ALTER TABLE `synex_group_duty_sessions`
            ADD CONSTRAINT `fk_group_duty_sessions_assignment`
                FOREIGN KEY (`assignment_id`) REFERENCES `synex_group_assignments` (`id`) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_sessions'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_sessions_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_duty_sessions`
            ADD CONSTRAINT `chk_group_duty_sessions_metadata_json`
                CHECK (JSON_VALID(`metadata_json`) AND OCTET_LENGTH(`metadata_json`) <= 32768);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_events'
            AND `COLUMN_NAME` = 'assignment_id'
    ) THEN
        ALTER TABLE `synex_group_duty_events` ADD COLUMN `assignment_id` BIGINT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_events'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_duty_events` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;
    UPDATE `synex_group_duty_events`
    SET `metadata_json` = '{}'
    WHERE `metadata_json` IS NULL;
    ALTER TABLE `synex_group_duty_events`
        MODIFY COLUMN `assignment_id` BIGINT UNSIGNED NULL,
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_events'
            AND `INDEX_NAME` = 'idx_group_duty_events_assignment'
    ) THEN
        ALTER TABLE `synex_group_duty_events`
            ADD KEY `idx_group_duty_events_assignment` (`assignment_id`, `occurred_at`, `id`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_events'
            AND `CONSTRAINT_NAME` = 'fk_group_duty_events_assignment'
    ) THEN
        ALTER TABLE `synex_group_duty_events`
            ADD CONSTRAINT `fk_group_duty_events_assignment`
                FOREIGN KEY (`assignment_id`) REFERENCES `synex_group_assignments` (`id`) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_events'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_events_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_duty_events`
            ADD CONSTRAINT `chk_group_duty_events_metadata_json`
                CHECK (JSON_VALID(`metadata_json`) AND OCTET_LENGTH(`metadata_json`) <= 32768);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `COLUMN_NAME` = 'parent_assignment_id'
    ) THEN
        ALTER TABLE `synex_group_assignments` ADD COLUMN `parent_assignment_id` BIGINT UNSIGNED NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `COLUMN_NAME` = 'assignment_type'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD COLUMN `assignment_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `COLUMN_NAME` = 'metadata_json'
    ) THEN
        ALTER TABLE `synex_group_assignments` ADD COLUMN `metadata_json` LONGTEXT NULL;
    END IF;
    UPDATE `synex_group_assignments`
    SET `display_name` = CASE WHEN CHAR_LENGTH(`display_name`) > 0
            THEN `display_name` ELSE `assignment_key` END,
        `assignment_type` = COALESCE(`assignment_type`, 'legacy'),
        `metadata_json` = COALESCE(`metadata_json`, '{}')
    WHERE `assignment_type` IS NULL OR `metadata_json` IS NULL OR CHAR_LENGTH(`display_name`) = 0;
    ALTER TABLE `synex_group_assignments`
        MODIFY COLUMN `parent_assignment_id` BIGINT UNSIGNED NULL,
        MODIFY COLUMN `assignment_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `metadata_json` LONGTEXT NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `INDEX_NAME` = 'idx_group_assignments_parent'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD KEY `idx_group_assignments_parent` (`parent_assignment_id`, `status`, `id`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `CONSTRAINT_NAME` = 'fk_group_assignments_parent'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD CONSTRAINT `fk_group_assignments_parent`
                FOREIGN KEY (`parent_assignment_id`) REFERENCES `synex_group_assignments` (`id`) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `CONSTRAINT_NAME` = 'chk_group_assignments_name'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD CONSTRAINT `chk_group_assignments_name`
                CHECK (CHAR_LENGTH(`display_name`) BETWEEN 1 AND 96);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `CONSTRAINT_NAME` = 'chk_group_assignments_type'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD CONSTRAINT `chk_group_assignments_type`
                CHECK (`assignment_type` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignments'
            AND `CONSTRAINT_NAME` = 'chk_group_assignments_metadata_json'
    ) THEN
        ALTER TABLE `synex_group_assignments`
            ADD CONSTRAINT `chk_group_assignments_metadata_json` CHECK (JSON_VALID(`metadata_json`));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `COLUMN_NAME` = 'public_id'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `COLUMN_NAME` = 'role_key'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD COLUMN `role_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    UPDATE `synex_group_assignment_members`
    SET `public_id` = COALESCE(
            `public_id`,
            CAST(CONCAT('gamem_', SUBSTRING(SHA2(CONCAT('assignment-member:', `id`), 256), 1, 32))
                AS CHAR CHARACTER SET ascii)),
        `role_key` = COALESCE(`role_key`, CAST('member' AS CHAR CHARACTER SET ascii))
    WHERE `public_id` IS NULL OR `role_key` IS NULL;
    ALTER TABLE `synex_group_assignment_members`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `role_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `INDEX_NAME` = 'uq_group_assignment_members_public'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD UNIQUE KEY `uq_group_assignment_members_public` (`public_id`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `CONSTRAINT_NAME` = 'chk_group_assignment_members_public'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD CONSTRAINT `chk_group_assignment_members_public`
                CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `CONSTRAINT_NAME` = 'chk_group_assignment_members_role'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD CONSTRAINT `chk_group_assignment_members_role`
                CHECK (`role_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'namespace'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `namespace` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'contract_type'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `contract_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'capability'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `capability` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'schema_version'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas` ADD COLUMN `schema_version` INT UNSIGNED NULL;
    END IF;
    UPDATE `synex_group_attribute_schemas`
    SET `namespace` = COALESCE(`namespace`, `owner_resource`),
        `contract_type` = COALESCE(`contract_type`, `value_kind`),
        `schema_version` = COALESCE(`schema_version`, 1)
    WHERE `namespace` IS NULL OR `contract_type` IS NULL OR `schema_version` IS NULL;
    ALTER TABLE `synex_group_attribute_schemas`
        MODIFY COLUMN `namespace` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `contract_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `capability` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
        MODIFY COLUMN `schema_version` INT UNSIGNED NOT NULL;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `INDEX_NAME` = 'uq_group_attribute_schemas_namespace'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD UNIQUE KEY `uq_group_attribute_schemas_namespace`
                (`namespace`, `group_type_scope_id`, `attribute_key`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_namespace'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD CONSTRAINT `chk_group_attribute_schemas_namespace`
                CHECK (`namespace` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_contract_type'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD CONSTRAINT `chk_group_attribute_schemas_contract_type`
                CHECK (`contract_type` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_capability'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD CONSTRAINT `chk_group_attribute_schemas_capability`
                CHECK (`capability` IS NULL OR `capability` REGEXP '^[a-z][a-z0-9._*-]{0,95}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_schema_version'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD CONSTRAINT `chk_group_attribute_schemas_schema_version` CHECK (`schema_version` > 0);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            (`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'membership_limit'
                AND `DATA_TYPE` = 'int' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'YES')
            OR (`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'schema_version'
                AND `DATA_TYPE` = 'int' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'dynamic_creation'
                AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'metadata_json'
                AND `DATA_TYPE` = 'longtext' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_organization_profiles'
                AND `COLUMN_NAME` IN ('name', 'label') AND `DATA_TYPE` = 'varchar'
                AND `CHARACTER_MAXIMUM_LENGTH` = 96 AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_organization_profiles' AND `COLUMN_NAME` = 'description'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 1024
                AND `IS_NULLABLE` = 'YES')
            OR (`TABLE_NAME` = 'synex_group_organization_profiles' AND `COLUMN_NAME` = 'dynamic'
                AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_organization_profiles' AND `COLUMN_NAME` = 'metadata_json'
                AND `DATA_TYPE` = 'longtext' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_relationships' AND `COLUMN_NAME` = 'metadata_json'
                AND `DATA_TYPE` = 'longtext' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_applications' AND `COLUMN_NAME` = 'schema_version'
                AND `DATA_TYPE` = 'int' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` IN ('synex_group_duty_sessions', 'synex_group_duty_events')
                AND `COLUMN_NAME` = 'assignment_id' AND `DATA_TYPE` = 'bigint'
                AND `COLUMN_TYPE` LIKE '%unsigned%' AND `IS_NULLABLE` = 'YES')
            OR (`TABLE_NAME` IN ('synex_group_duty_sessions', 'synex_group_duty_events')
                AND `COLUMN_NAME` = 'metadata_json' AND `DATA_TYPE` = 'longtext'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_assignments' AND `COLUMN_NAME` = 'parent_assignment_id'
                AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'YES')
            OR (`TABLE_NAME` = 'synex_group_assignments' AND `COLUMN_NAME` = 'assignment_type'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 64
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_assignments' AND `COLUMN_NAME` = 'metadata_json'
                AND `DATA_TYPE` = 'longtext' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_assignment_members' AND `COLUMN_NAME` = 'public_id'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 48
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_assignment_members' AND `COLUMN_NAME` = 'role_key'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 64
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_attribute_schemas'
                AND `COLUMN_NAME` IN ('namespace', 'contract_type') AND `DATA_TYPE` = 'varchar'
                AND `CHARACTER_MAXIMUM_LENGTH` = 64 AND `CHARACTER_SET_NAME` = 'ascii'
                AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO')
            OR (`TABLE_NAME` = 'synex_group_attribute_schemas' AND `COLUMN_NAME` = 'capability'
                AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 96
                AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                AND `IS_NULLABLE` = 'YES')
            OR (`TABLE_NAME` = 'synex_group_attribute_schemas' AND `COLUMN_NAME` = 'schema_version'
                AND `DATA_TYPE` = 'int' AND `COLUMN_TYPE` LIKE '%unsigned%'
                AND `IS_NULLABLE` = 'NO')
        )
    ) <> 24 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 column metadata verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND (
                (`table_constraint`.`TABLE_NAME` = 'synex_group_types' AND (
                    (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_types_schema_version'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%schema_version%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_types_dynamic_creation'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%dynamic_creation%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_types_membership_limit'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%membership_limit%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_types_metadata_json'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%')))
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_organization_profiles' AND (
                    (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_profiles_name_label'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%name%label%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_profiles_description'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%description%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_profiles_dynamic'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%dynamic%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_profiles_metadata_json'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%')))
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_relationships'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_relationships_metadata_json'
                    AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_applications'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_applications_schema_version'
                    AND `check_constraint`.`CHECK_CLAUSE` LIKE '%schema_version%')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_duty_sessions'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_duty_sessions_metadata_json'
                    AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%32768%')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_duty_events'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_duty_events_metadata_json'
                    AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%32768%')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_assignments' AND (
                    (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_assignments_name'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%display_name%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_assignments_type'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%assignment_type%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_assignments_metadata_json'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%metadata_json%')))
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_assignment_members' AND (
                    (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_assignment_members_public'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%public_id%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_assignment_members_role'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%role_key%')))
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_attribute_schemas' AND (
                    (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_attribute_schemas_namespace'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%namespace%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_attribute_schemas_contract_type'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%contract_type%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_attribute_schemas_capability'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%capability%')
                    OR (`table_constraint`.`CONSTRAINT_NAME` = 'chk_group_attribute_schemas_schema_version'
                        AND `check_constraint`.`CHECK_CLAUSE` LIKE '%schema_version%')))
            )
    ) <> 21 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 check constraint verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `INDEX_NAME` IN (
            'idx_group_duty_sessions_assignment', 'idx_group_duty_events_assignment',
            'idx_group_assignments_parent', 'uq_group_assignment_members_public',
            'uq_group_attribute_schemas_namespace'
        ) AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND (
                (`TABLE_NAME` = 'synex_group_duty_sessions'
                    AND `INDEX_NAME` = 'idx_group_duty_sessions_assignment' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'assignment_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'status')
                        OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id')))
                OR (`TABLE_NAME` = 'synex_group_duty_events'
                    AND `INDEX_NAME` = 'idx_group_duty_events_assignment' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'assignment_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'occurred_at')
                        OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id')))
                OR (`TABLE_NAME` = 'synex_group_assignments'
                    AND `INDEX_NAME` = 'idx_group_assignments_parent' AND `NON_UNIQUE` = 1
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'parent_assignment_id')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'status')
                        OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id')))
                OR (`TABLE_NAME` = 'synex_group_assignment_members'
                    AND `INDEX_NAME` = 'uq_group_assignment_members_public' AND `NON_UNIQUE` = 0
                    AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'public_id')
                OR (`TABLE_NAME` = 'synex_group_attribute_schemas'
                    AND `INDEX_NAME` = 'uq_group_attribute_schemas_namespace' AND `NON_UNIQUE` = 0
                    AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'namespace')
                        OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'group_type_scope_id')
                        OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'attribute_key')))
            )
    ) <> 13 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            ((`TABLE_NAME` = 'synex_group_duty_sessions'
                    AND `INDEX_NAME` = 'idx_group_duty_sessions_assignment')
                OR (`TABLE_NAME` = 'synex_group_duty_events'
                    AND `INDEX_NAME` = 'idx_group_duty_events_assignment')
                OR (`TABLE_NAME` = 'synex_group_assignments'
                    AND `INDEX_NAME` = 'idx_group_assignments_parent')
                OR (`TABLE_NAME` = 'synex_group_attribute_schemas'
                    AND `INDEX_NAME` = 'uq_group_attribute_schemas_namespace'))
                AND `SEQ_IN_INDEX` > 3
            OR (`TABLE_NAME` = 'synex_group_assignment_members'
                AND `INDEX_NAME` = 'uq_group_assignment_members_public' AND `SEQ_IN_INDEX` > 1)
        )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE` AS `usage`
        INNER JOIN `information_schema`.`REFERENTIAL_CONSTRAINTS` AS `reference`
            ON `reference`.`CONSTRAINT_SCHEMA` = `usage`.`CONSTRAINT_SCHEMA`
            AND `reference`.`CONSTRAINT_NAME` = `usage`.`CONSTRAINT_NAME`
        WHERE `usage`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `reference`.`DELETE_RULE` = 'RESTRICT'
            AND `usage`.`REFERENCED_TABLE_NAME` = 'synex_group_assignments'
            AND `usage`.`REFERENCED_COLUMN_NAME` = 'id'
            AND (
                (`usage`.`TABLE_NAME` = 'synex_group_duty_sessions'
                    AND `usage`.`COLUMN_NAME` = 'assignment_id'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_duty_sessions_assignment')
                OR (`usage`.`TABLE_NAME` = 'synex_group_duty_events'
                    AND `usage`.`COLUMN_NAME` = 'assignment_id'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_duty_events_assignment')
                OR (`usage`.`TABLE_NAME` = 'synex_group_assignments'
                    AND `usage`.`COLUMN_NAME` = 'parent_assignment_id'
                    AND `usage`.`CONSTRAINT_NAME` = 'fk_group_assignments_parent')
            )
    ) <> 3 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 foreign key verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `synex_group_membership_states`
        WHERE `state_key` IN (
            'DRAFT', 'INVITED', 'APPLICANT', 'UNDER_REVIEW', 'APPROVED', 'PROBATION',
            'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE', 'TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED'
        )
            AND `owner_resource` = 'synex_groups' AND `status` = 'active'
            AND ((`state_key` IN ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
                    AND `terminal_state` = 1)
                OR (`state_key` NOT IN ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
                    AND `terminal_state` = 0))
    ) <> 14 OR EXISTS (
        SELECT 1 FROM `synex_group_types` AS `group_type`
        CROSS JOIN `synex_group_membership_states` AS `state`
        LEFT JOIN `synex_group_type_membership_states` AS `allowed`
            ON `allowed`.`group_type_id` = `group_type`.`id`
            AND `allowed`.`state_key` = `state`.`state_key`
        WHERE `state`.`status` = 'active' AND `allowed`.`group_type_id` IS NULL
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_types` AS `group_type`
        CROSS JOIN `synex_group_duty_states` AS `state`
        LEFT JOIN `synex_group_type_duty_states` AS `allowed`
            ON `allowed`.`group_type_id` = `group_type`.`id`
            AND `allowed`.`state_key` = `state`.`state_key`
        WHERE `state`.`status` = 'active' AND `allowed`.`group_type_id` IS NULL
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_types`
        WHERE `schema_version` < 1 OR `dynamic_creation` NOT IN (0, 1)
            OR NOT JSON_VALID(`metadata_json`)
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_organization_profiles`
        WHERE CHAR_LENGTH(`name`) NOT BETWEEN 1 AND 96
            OR CHAR_LENGTH(`label`) NOT BETWEEN 1 AND 96
            OR `dynamic` NOT IN (0, 1) OR NOT JSON_VALID(`metadata_json`)
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_relationships` WHERE NOT JSON_VALID(`metadata_json`)
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_applications` WHERE `schema_version` < 1
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_duty_sessions`
        WHERE NOT JSON_VALID(`metadata_json`) OR OCTET_LENGTH(`metadata_json`) > 32768
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_duty_events`
        WHERE NOT JSON_VALID(`metadata_json`) OR OCTET_LENGTH(`metadata_json`) > 32768
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_assignments`
        WHERE CHAR_LENGTH(`display_name`) NOT BETWEEN 1 AND 96
            OR `assignment_type` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
            OR NOT JSON_VALID(`metadata_json`)
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_assignment_members`
        WHERE `public_id` NOT REGEXP '^[a-z][a-z0-9_]{7,47}$'
            OR `role_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 009 data backfill verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_009_contract_storage_compatibility`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_009_contract_storage_compatibility`;
