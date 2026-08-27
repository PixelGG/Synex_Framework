DROP PROCEDURE IF EXISTS `synex_groups_migrate_013_contract_text_bounds`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_013_contract_text_bounds`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_roles'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 013 prerequisite table verification failed';
    END IF;

    ALTER TABLE `synex_group_roles`
        MODIFY COLUMN `description` VARCHAR(1024) NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_roles'
            AND `COLUMN_NAME` = 'description' AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 1024 AND `IS_NULLABLE` = 'YES'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 013 role description verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_013_contract_text_bounds`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_013_contract_text_bounds`;
