DROP PROCEDURE IF EXISTS `synex_groups_migrate_015_primary_membership_public_ids`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_015_primary_membership_public_ids`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 015 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `COLUMN_NAME` = 'public_id'
    ) THEN
        ALTER TABLE `synex_group_primary_memberships_by_type`
            ADD COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL
                AFTER `membership_id`;
    END IF;

    UPDATE `synex_group_primary_memberships_by_type`
    SET `public_id` = CONCAT(
        'gprimary_', SUBSTRING(SHA2(CONCAT(
            'primary:', `character_id`, ':', `group_type_id`), 256), 1, 32))
    WHERE `public_id` IS NULL;

    ALTER TABLE `synex_group_primary_memberships_by_type`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `INDEX_NAME` = 'uq_group_primary_by_type_public'
    ) THEN
        ALTER TABLE `synex_group_primary_memberships_by_type`
            ADD UNIQUE KEY `uq_group_primary_by_type_public` (`public_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `CONSTRAINT_NAME` = 'chk_group_primary_by_type_public'
    ) THEN
        ALTER TABLE `synex_group_primary_memberships_by_type`
            ADD CONSTRAINT `chk_group_primary_by_type_public`
                CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `COLUMN_NAME` = 'public_id' AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `INDEX_NAME` = 'uq_group_primary_by_type_public'
            AND `NON_UNIQUE` = 0 AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'public_id'
            AND `SUB_PART` IS NULL
    ) <> 1 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `INDEX_NAME` = 'uq_group_primary_by_type_public' AND `SEQ_IN_INDEX` > 1
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_primary_by_type_public'
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%public_id%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%7,47%'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_primary_memberships_by_type`
        WHERE `public_id` NOT REGEXP '^[a-z][a-z0-9_]{7,47}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 015 public identifier verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_015_primary_membership_public_ids`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_015_primary_membership_public_ids`;
