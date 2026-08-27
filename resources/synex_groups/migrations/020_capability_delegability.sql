DROP PROCEDURE IF EXISTS `synex_groups_migrate_020_capability_delegability`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_020_capability_delegability`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_default_capabilities',
                'synex_group_grade_capabilities',
                'synex_group_role_capabilities',
                'synex_group_membership_capabilities'
            )
            AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 4 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 020 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_default_capabilities'
            AND `COLUMN_NAME` = 'delegable'
    ) THEN
        ALTER TABLE `synex_group_default_capabilities`
            ADD COLUMN `delegable` TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER `scope_ref`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_grade_capabilities'
            AND `COLUMN_NAME` = 'delegable'
    ) THEN
        ALTER TABLE `synex_group_grade_capabilities`
            ADD COLUMN `delegable` TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER `effect`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_role_capabilities'
            AND `COLUMN_NAME` = 'delegable'
    ) THEN
        ALTER TABLE `synex_group_role_capabilities`
            ADD COLUMN `delegable` TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER `scope_ref`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_capabilities'
            AND `COLUMN_NAME` = 'delegable'
    ) THEN
        ALTER TABLE `synex_group_membership_capabilities`
            ADD COLUMN `delegable` TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER `scope_ref`;
    END IF;

    UPDATE `synex_group_default_capabilities`
        SET `delegable` = 0 WHERE `effect` = 'deny' AND `delegable` <> 0;
    UPDATE `synex_group_grade_capabilities`
        SET `delegable` = 0 WHERE `effect` = 'deny' AND `delegable` <> 0;
    UPDATE `synex_group_role_capabilities`
        SET `delegable` = 0 WHERE `effect` = 'deny' AND `delegable` <> 0;
    UPDATE `synex_group_membership_capabilities`
        SET `delegable` = 0 WHERE `effect` = 'deny' AND `delegable` <> 0;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_default_capabilities'
            AND `CONSTRAINT_NAME` = 'chk_group_default_capability_delegable'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_default_capabilities`
            ADD CONSTRAINT `chk_group_default_capability_delegable`
            CHECK (`delegable` IN (0, 1) AND (`effect` = 'allow' OR `delegable` = 0));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_grade_capabilities'
            AND `CONSTRAINT_NAME` = 'chk_group_grade_capability_delegable'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_grade_capabilities`
            ADD CONSTRAINT `chk_group_grade_capability_delegable`
            CHECK (`delegable` IN (0, 1) AND (`effect` = 'allow' OR `delegable` = 0));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_role_capabilities'
            AND `CONSTRAINT_NAME` = 'chk_group_role_capability_delegable'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_role_capabilities`
            ADD CONSTRAINT `chk_group_role_capability_delegable`
            CHECK (`delegable` IN (0, 1) AND (`effect` = 'allow' OR `delegable` = 0));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_capabilities'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_capability_delegable'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_membership_capabilities`
            ADD CONSTRAINT `chk_group_membership_capability_delegable`
            CHECK (`delegable` IN (0, 1) AND (`effect` = 'allow' OR `delegable` = 0));
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_default_capabilities',
                'synex_group_grade_capabilities',
                'synex_group_role_capabilities',
                'synex_group_membership_capabilities'
            )
            AND `COLUMN_NAME` = 'delegable'
            AND `DATA_TYPE` = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND `IS_NULLABLE` = 'NO'
            AND TRIM(BOTH '''' FROM `COLUMN_DEFAULT`) = '0'
    ) <> 4 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` IN (
                'chk_group_default_capability_delegable',
                'chk_group_grade_capability_delegable',
                'chk_group_role_capability_delegable',
                'chk_group_membership_capability_delegable'
            )
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) <> 4 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 020 delegability metadata verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_020_capability_delegability`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_020_capability_delegability`;
