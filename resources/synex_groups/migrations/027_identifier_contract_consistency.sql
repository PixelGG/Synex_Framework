DROP PROCEDURE IF EXISTS `synex_groups_migrate_027_identifier_contract_consistency`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_027_identifier_contract_consistency`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` IN (
            'synex_groups',
            'synex_group_memberships',
            'synex_group_grades',
            'synex_group_types',
            'synex_group_relation_types',
            'synex_group_roles'
        ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 6 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 027 prerequisite verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_groups'
            AND `CONSTRAINT_NAME` = 'chk_groups_type'
    ) THEN
        ALTER TABLE `synex_groups` DROP CONSTRAINT `chk_groups_type`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_group_memberships'
            AND `CONSTRAINT_NAME` = 'chk_group_memberships_role_key'
    ) THEN
        ALTER TABLE `synex_group_memberships`
            DROP CONSTRAINT `chk_group_memberships_role_key`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_group_grades'
            AND `CONSTRAINT_NAME` = 'chk_group_grades_key'
    ) THEN
        ALTER TABLE `synex_group_grades` DROP CONSTRAINT `chk_group_grades_key`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_key'
    ) THEN
        ALTER TABLE `synex_group_types` DROP CONSTRAINT `chk_group_types_key`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `CONSTRAINT_NAME` = 'chk_group_relation_types_key'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            DROP CONSTRAINT `chk_group_relation_types_key`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND `TABLE_NAME` = 'synex_group_roles'
            AND `CONSTRAINT_NAME` = 'chk_group_roles_key'
    ) THEN
        ALTER TABLE `synex_group_roles` DROP CONSTRAINT `chk_group_roles_key`;
    END IF;

    ALTER TABLE `synex_groups`
        MODIFY COLUMN `group_type`
            VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;
    ALTER TABLE `synex_group_memberships`
        MODIFY COLUMN `role_key`
            VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;
    ALTER TABLE `synex_group_grades`
        MODIFY COLUMN `grade_key`
            VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    ALTER TABLE `synex_groups`
        ADD CONSTRAINT `chk_groups_type`
            CHECK (`group_type` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    ALTER TABLE `synex_group_memberships`
        ADD CONSTRAINT `chk_group_memberships_role_key`
            CHECK (`role_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    ALTER TABLE `synex_group_grades`
        ADD CONSTRAINT `chk_group_grades_key`
            CHECK (`grade_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    ALTER TABLE `synex_group_types`
        ADD CONSTRAINT `chk_group_types_key`
            CHECK (`type_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    ALTER TABLE `synex_group_relation_types`
        ADD CONSTRAINT `chk_group_relation_types_key`
            CHECK (`type_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');
    ALTER TABLE `synex_group_roles`
        ADD CONSTRAINT `chk_group_roles_key`
            CHECK (`role_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 64
            AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO'
            AND (
                (`TABLE_NAME` = 'synex_groups' AND `COLUMN_NAME` = 'group_type')
                OR (`TABLE_NAME` = 'synex_group_memberships' AND `COLUMN_NAME` = 'role_key')
                OR (`TABLE_NAME` = 'synex_group_grades' AND `COLUMN_NAME` = 'grade_key')
                OR (`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'type_key')
                OR (`TABLE_NAME` = 'synex_group_relation_types' AND `COLUMN_NAME` = 'type_key')
                OR (`TABLE_NAME` = 'synex_group_roles' AND `COLUMN_NAME` = 'role_key')
            )
    ) <> 6 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND (
                (`TABLE_NAME` = 'synex_groups'
                    AND `CONSTRAINT_NAME` = 'chk_groups_type')
                OR (`TABLE_NAME` = 'synex_group_memberships'
                    AND `CONSTRAINT_NAME` = 'chk_group_memberships_role_key')
                OR (`TABLE_NAME` = 'synex_group_grades'
                    AND `CONSTRAINT_NAME` = 'chk_group_grades_key')
                OR (`TABLE_NAME` = 'synex_group_types'
                    AND `CONSTRAINT_NAME` = 'chk_group_types_key')
                OR (`TABLE_NAME` = 'synex_group_relation_types'
                    AND `CONSTRAINT_NAME` = 'chk_group_relation_types_key')
                OR (`TABLE_NAME` = 'synex_group_roles'
                    AND `CONSTRAINT_NAME` = 'chk_group_roles_key')
            )
    ) <> 6 OR EXISTS (
        SELECT 1 FROM `synex_groups`
        WHERE `group_type` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_memberships`
        WHERE `role_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_grades`
        WHERE `grade_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_types`
        WHERE `type_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_relation_types`
        WHERE `type_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_roles`
        WHERE `role_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 027 identifier contract verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_027_identifier_contract_consistency`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_027_identifier_contract_consistency`;
