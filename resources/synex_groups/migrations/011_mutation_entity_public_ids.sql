DROP PROCEDURE IF EXISTS `synex_groups_migrate_011_mutation_entity_public_ids`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_011_mutation_entity_public_ids`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 011 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `COLUMN_NAME` = 'public_id'
    ) THEN
        ALTER TABLE `synex_group_membership_attributes`
            ADD COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;
    END IF;

    UPDATE `synex_group_membership_attributes`
    SET `public_id` = CONCAT(
        'gattr_', SUBSTRING(SHA2(CONCAT('membership-attribute:', `id`), 256), 1, 32))
    WHERE `public_id` IS NULL;

    ALTER TABLE `synex_group_membership_attributes`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `INDEX_NAME` = 'uq_group_membership_attributes_public'
    ) THEN
        ALTER TABLE `synex_group_membership_attributes`
            ADD UNIQUE KEY `uq_group_membership_attributes_public` (`public_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_attributes_public'
    ) THEN
        ALTER TABLE `synex_group_membership_attributes`
            ADD CONSTRAINT `chk_group_membership_attributes_public`
                CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `COLUMN_NAME` = 'public_id' AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `INDEX_NAME` = 'uq_group_membership_attributes_public'
            AND `NON_UNIQUE` = 0 AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'public_id'
            AND `SUB_PART` IS NULL
    ) <> 1 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_attributes'
            AND `INDEX_NAME` = 'uq_group_membership_attributes_public' AND `SEQ_IN_INDEX` > 1
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`TABLE_NAME` = 'synex_group_membership_attributes'
            AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_membership_attributes_public'
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%public_id%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%7,47%'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_membership_attributes`
        WHERE `public_id` NOT REGEXP '^[a-z][a-z0-9_]{7,47}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 011 public identifier verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_011_mutation_entity_public_ids`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_011_mutation_entity_public_ids`;
