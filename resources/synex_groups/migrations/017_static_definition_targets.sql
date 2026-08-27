DROP PROCEDURE IF EXISTS `synex_groups_migrate_017_static_definition_targets`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_017_static_definition_targets`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 017 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `COLUMN_NAME` = 'target_group_id'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD COLUMN `target_group_id` BIGINT UNSIGNED NULL AFTER `definition_key`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `INDEX_NAME` = 'uq_group_definition_target'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD UNIQUE KEY `uq_group_definition_target` (`target_group_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `INDEX_NAME` = 'idx_group_definition_target_state'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD KEY `idx_group_definition_target_state` (`state`, `target_group_id`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'fk_group_definition_target'
            AND `CONSTRAINT_TYPE` = 'FOREIGN KEY'
    ) THEN
        ALTER TABLE `synex_group_definition_sets`
            ADD CONSTRAINT `fk_group_definition_target`
            FOREIGN KEY (`target_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `COLUMN_NAME` = 'target_group_id'
            AND `DATA_TYPE` = 'bigint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND `IS_NULLABLE` = 'YES'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `INDEX_NAME` = 'uq_group_definition_target'
            AND `COLUMN_NAME` = 'target_group_id'
            AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `INDEX_NAME` = 'uq_group_definition_target'
    ) <> 1 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `INDEX_NAME` = 'idx_group_definition_target_state'
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'target_group_id')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'))
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`REFERENTIAL_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'fk_group_definition_target'
            AND `DELETE_RULE` = 'RESTRICT'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`KEY_COLUMN_USAGE`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'fk_group_definition_target'
            AND `COLUMN_NAME` = 'target_group_id'
            AND `REFERENCED_TABLE_NAME` = 'synex_groups'
            AND `REFERENCED_COLUMN_NAME` = 'id'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 017 target metadata verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_017_static_definition_targets`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_017_static_definition_targets`;
