DROP PROCEDURE IF EXISTS `synex_groups_migrate_012_group_history_scope`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_012_group_history_scope`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN ('synex_group_domain_history', 'synex_group_domain_history_archive')
            AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 012 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history'
            AND `COLUMN_NAME` = 'group_public_id'
    ) THEN
        ALTER TABLE `synex_group_domain_history`
            ADD COLUMN `group_public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL
                AFTER `aggregate_version`;
    END IF;

    UPDATE `synex_group_domain_history`
    SET `group_public_id` = CASE
        WHEN `aggregate_type` = 'group' THEN `aggregate_id`
        WHEN `after_json` IS NOT NULL
            AND JSON_VALID(`after_json`)
            AND JSON_UNQUOTE(JSON_EXTRACT(`after_json`, '$.group_id'))
                REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'
            THEN JSON_UNQUOTE(JSON_EXTRACT(`after_json`, '$.group_id'))
        ELSE NULL
    END
    WHERE `group_public_id` IS NULL;

    ALTER TABLE `synex_group_domain_history`
        MODIFY COLUMN `group_public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history'
            AND `INDEX_NAME` = 'idx_group_domain_history_group'
    ) THEN
        ALTER TABLE `synex_group_domain_history`
            ADD KEY `idx_group_domain_history_group` (`group_public_id`, `occurred_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history'
            AND `CONSTRAINT_NAME` = 'chk_group_domain_history_group'
    ) THEN
        ALTER TABLE `synex_group_domain_history`
            ADD CONSTRAINT `chk_group_domain_history_group`
                CHECK (`group_public_id` IS NULL
                    OR `group_public_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history_archive'
            AND `COLUMN_NAME` = 'group_public_id'
    ) THEN
        ALTER TABLE `synex_group_domain_history_archive`
            ADD COLUMN `group_public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL
                AFTER `aggregate_version`;
    END IF;

    UPDATE `synex_group_domain_history_archive`
    SET `group_public_id` = CASE
        WHEN `aggregate_type` = 'group' THEN `aggregate_id`
        WHEN `after_json` IS NOT NULL
            AND JSON_VALID(`after_json`)
            AND JSON_UNQUOTE(JSON_EXTRACT(`after_json`, '$.group_id'))
                REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'
            THEN JSON_UNQUOTE(JSON_EXTRACT(`after_json`, '$.group_id'))
        ELSE NULL
    END
    WHERE `group_public_id` IS NULL;

    ALTER TABLE `synex_group_domain_history_archive`
        MODIFY COLUMN `group_public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history_archive'
            AND `INDEX_NAME` = 'idx_group_history_archive_group'
    ) THEN
        ALTER TABLE `synex_group_domain_history_archive`
            ADD KEY `idx_group_history_archive_group` (`group_public_id`, `occurred_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history_archive'
            AND `CONSTRAINT_NAME` = 'chk_group_history_archive_group'
    ) THEN
        ALTER TABLE `synex_group_domain_history_archive`
            ADD CONSTRAINT `chk_group_history_archive_group`
                CHECK (`group_public_id` IS NULL
                    OR `group_public_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$');
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN ('synex_group_domain_history', 'synex_group_domain_history_archive')
            AND `COLUMN_NAME` = 'group_public_id' AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'YES'
    ) <> 2 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND (
                (`TABLE_NAME` = 'synex_group_domain_history'
                    AND `INDEX_NAME` = 'idx_group_domain_history_group')
                OR (`TABLE_NAME` = 'synex_group_domain_history_archive'
                    AND `INDEX_NAME` = 'idx_group_history_archive_group')
            )
            AND `NON_UNIQUE` = 1 AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND (
                (`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'group_public_id')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'occurred_at')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id')
            )
    ) <> 6 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `INDEX_NAME` IN ('idx_group_domain_history_group', 'idx_group_history_archive_group')
            AND `SEQ_IN_INDEX` > 3
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`CONSTRAINT_NAME` IN (
                'chk_group_domain_history_group', 'chk_group_history_archive_group')
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%group_public_id%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%7,47%'
    ) <> 2 OR EXISTS (
        SELECT 1 FROM `synex_group_domain_history`
        WHERE `group_public_id` IS NOT NULL
            AND `group_public_id` NOT REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_domain_history_archive`
        WHERE `group_public_id` IS NOT NULL
            AND `group_public_id` NOT REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 012 history scope verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_012_group_history_scope`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_012_group_history_scope`;
