CREATE TABLE IF NOT EXISTS `synex_group_type_default_grades` (
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `grade_key` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `rank_value` SMALLINT NOT NULL,
    `member_limit` INT UNSIGNED NULL,
    `sort_order` TINYINT UNSIGNED NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_type_id`, `grade_key`),
    UNIQUE KEY `uq_group_type_default_grades_order` (`group_type_id`, `sort_order`),
    KEY `idx_group_type_default_grades_rank`
        (`group_type_id`, `rank_value`, `grade_key`),
    CONSTRAINT `fk_group_type_default_grades_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_type_default_grades_key`
        CHECK (`grade_key` REGEXP '^[a-z][a-z0-9_]{1,47}$' AND `grade_key` <> 'owner'),
    CONSTRAINT `chk_group_type_default_grades_label`
        CHECK (CHAR_LENGTH(`display_name`) BETWEEN 1 AND 96),
    CONSTRAINT `chk_group_type_default_grades_rank`
        CHECK (`rank_value` BETWEEN -32768 AND 32766),
    CONSTRAINT `chk_group_type_default_grades_limit`
        CHECK (`member_limit` IS NULL OR `member_limit` BETWEEN 1 AND 100000),
    CONSTRAINT `chk_group_type_default_grades_order` CHECK (`sort_order` < 32),
    CONSTRAINT `chk_group_type_default_grades_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_type_default_roles` (
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `role_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `description` VARCHAR(1024) NULL,
    `assignable` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `exclusive` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `holder_limit` INT UNSIGNED NULL,
    `sort_order` TINYINT UNSIGNED NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_type_id`, `role_key`),
    UNIQUE KEY `uq_group_type_default_roles_order` (`group_type_id`, `sort_order`),
    CONSTRAINT `fk_group_type_default_roles_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_type_default_roles_key`
        CHECK (`role_key` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_type_default_roles_label`
        CHECK (CHAR_LENGTH(`display_name`) BETWEEN 1 AND 96),
    CONSTRAINT `chk_group_type_default_roles_description`
        CHECK (`description` IS NULL OR CHAR_LENGTH(`description`) <= 1024),
    CONSTRAINT `chk_group_type_default_roles_flags`
        CHECK (`assignable` IN (0, 1) AND `exclusive` IN (0, 1)),
    CONSTRAINT `chk_group_type_default_roles_limit`
        CHECK (`holder_limit` IS NULL OR `holder_limit` BETWEEN 1 AND 100000),
    CONSTRAINT `chk_group_type_default_roles_order` CHECK (`sort_order` < 32),
    CONSTRAINT `chk_group_type_default_roles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_023_dynamic_type_creation_policies`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_023_dynamic_type_creation_policies`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_types',
                'synex_group_type_default_grades',
                'synex_group_type_default_roles'
            )
            AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 3 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 023 prerequisite verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'membership_limit' AND `DATA_TYPE` = 'int'
            AND `IS_NULLABLE` = 'YES'
    ) THEN
        ALTER TABLE `synex_group_types`
            MODIFY COLUMN `membership_limit` INT UNSIGNED NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'active_membership_limit'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD COLUMN `active_membership_limit` INT UNSIGNED NULL
            AFTER `membership_limit`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'create_permission'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD COLUMN `create_permission`
                VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL
                DEFAULT 'synex.groups.create.migration_pending'
            AFTER `dynamic_creation`;
    END IF;

    UPDATE `synex_group_types`
        SET `create_permission` = CONCAT('synex.groups.create.', `type_key`)
        WHERE `create_permission` IS NULL
            OR `create_permission` = 'synex.groups.create.migration_pending';

    ALTER TABLE `synex_group_types`
        MODIFY COLUMN `create_permission`
            VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
            DEFAULT 'synex.groups.create.migration_pending';

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_active_membership_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_active_membership_limit`
                CHECK (`active_membership_limit` IS NULL
                    OR `active_membership_limit` BETWEEN 1 AND 100000);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_member_limit_order'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_member_limit_order`
                CHECK (`membership_limit` IS NULL OR `active_membership_limit` IS NULL
                    OR `active_membership_limit` <= `membership_limit`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_create_permission'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_create_permission`
                CHECK (`create_permission` REGEXP
                    '^synex\\.groups\\.create\\.[a-z][a-z0-9_.-]+$');
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND ((`COLUMN_NAME` = 'membership_limit'
                    AND `DATA_TYPE` = 'int' AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'active_membership_limit'
                    AND `DATA_TYPE` = 'int' AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'create_permission'
                    AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 96
                    AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                    AND `IS_NULLABLE` = 'NO'))
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` IN (
                'chk_group_types_membership_limit',
                'chk_group_types_active_membership_limit',
                'chk_group_types_member_limit_order',
                'chk_group_types_create_permission'
            ) AND `CONSTRAINT_TYPE` = 'CHECK'
    ) <> 4 OR EXISTS (
        SELECT 1 FROM `synex_group_types`
        WHERE `create_permission` NOT REGEXP
            '^synex\\.groups\\.create\\.[a-z][a-z0-9_.-]+$'
            OR `create_permission` = 'synex.groups.create.migration_pending'
            OR (`membership_limit` IS NOT NULL
                AND `membership_limit` NOT BETWEEN 1 AND 100000)
            OR (`active_membership_limit` IS NOT NULL
                AND `active_membership_limit` NOT BETWEEN 1 AND 100000)
            OR (`membership_limit` IS NOT NULL AND `active_membership_limit` IS NOT NULL
                AND `active_membership_limit` > `membership_limit`)
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 023 creation policy verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_023_dynamic_type_creation_policies`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_023_dynamic_type_creation_policies`;
