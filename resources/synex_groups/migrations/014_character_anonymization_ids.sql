DROP PROCEDURE IF EXISTS `synex_groups_migrate_014_character_anonymization_ids`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_014_character_anonymization_ids`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_character_deletions'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 014 prerequisite table verification failed';
    END IF;

    ALTER TABLE `synex_group_character_deletions`
        MODIFY COLUMN `anonymous_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_character_deletions'
            AND `CONSTRAINT_NAME` = 'chk_group_character_deletions_anonymous_ref'
    ) THEN
        ALTER TABLE `synex_group_character_deletions`
            DROP CONSTRAINT `chk_group_character_deletions_anonymous_ref`;
    END IF;

    ALTER TABLE `synex_group_character_deletions`
        ADD CONSTRAINT `chk_group_character_deletions_anonymous_ref`
            CHECK (`anonymous_ref` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$');

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_character_deletions'
            AND `COLUMN_NAME` = 'anonymous_ref' AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`TABLE_NAME` = 'synex_group_character_deletions'
            AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_character_deletions_anonymous_ref'
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%anonymous_ref%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%A-Za-z0-9_.:%-%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%7,47%'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_character_deletions`
        WHERE `anonymous_ref` NOT REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 014 anonymization identifier verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_014_character_anonymization_ids`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_014_character_anonymization_ids`;
