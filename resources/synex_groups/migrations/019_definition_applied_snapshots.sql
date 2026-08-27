DROP PROCEDURE IF EXISTS `synex_groups_migrate_019_definition_applied_snapshots`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_019_definition_applied_snapshots`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 019 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `COLUMN_NAME` = 'applied_definition_json'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD COLUMN `applied_definition_json` LONGTEXT NULL AFTER `applied_digest`;
    END IF;

    UPDATE `synex_group_definition_sets`
    SET `applied_definition_json` = `definition_json`
    WHERE `applied_digest` = `definition_digest`
        AND `applied_definition_json` IS NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'chk_group_definition_applied_json'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD CONSTRAINT `chk_group_definition_applied_json`
            CHECK (`applied_definition_json` IS NULL
                OR (`applied_digest` IS NOT NULL
                    AND JSON_VALID(`applied_definition_json`)));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `COLUMN_NAME` = 'applied_definition_json'
            AND `DATA_TYPE` = 'longtext'
            AND `IS_NULLABLE` = 'YES'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'chk_group_definition_applied_json'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_definition_sets`
        WHERE `applied_definition_json` IS NOT NULL
            AND (`applied_digest` IS NULL
                OR NOT JSON_VALID(`applied_definition_json`)
                OR CAST(LOWER(SHA2(`applied_definition_json`, 256)) AS BINARY)
                    <> CAST(`applied_digest` AS BINARY))
        LIMIT 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 019 snapshot verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_019_definition_applied_snapshots`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_019_definition_applied_snapshots`;
