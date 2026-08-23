DROP PROCEDURE IF EXISTS `synex_migrate_018_character_slot_reuse`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_018_character_slot_reuse`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `COLUMN_NAME` = 'active_slot_marker'
    ) THEN
        ALTER TABLE `synex_characters`
            ADD COLUMN `active_slot_marker` TINYINT UNSIGNED
                GENERATED ALWAYS AS (
                    CASE WHEN `deleted_at` IS NULL THEN 1 ELSE NULL END
                ) STORED AFTER `deleted_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `COLUMN_NAME` = 'active_slot_marker'
            AND LOWER(`DATA_TYPE`) = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND `IS_NULLABLE` = 'YES'
            AND UPPER(`EXTRA`) LIKE '%STORED GENERATED%'
            AND LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                `GENERATION_EXPRESSION`, '`', ''), ' ', ''), CHAR(9), ''),
                CHAR(10), ''), CHAR(13), ''), '(', ''), ')', ''))
                IN (
                    'casewhendeleted_atisnullthen1elsenullend',
                    'casewhenisnulldeleted_atthen1elsenullend',
                    'ifdeleted_atisnull,1,null',
                    'ifisnulldeleted_at,1,null'
                )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 018 active slot marker definition verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot_active'
    ) THEN
        ALTER TABLE `synex_characters`
            ADD UNIQUE KEY `uq_characters_user_slot_active`
                (`user_id`, `slot`, `active_slot_marker`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot_active'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'user_id'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot_active'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'slot'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot_active'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'active_slot_marker'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot_active' AND `SEQ_IN_INDEX` > 3
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 018 active character slot uniqueness verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_characters'
            AND `INDEX_NAME` = 'uq_characters_user_slot'
    ) THEN
        ALTER TABLE `synex_characters`
            DROP INDEX `uq_characters_user_slot`;
    END IF;
END;

-- synex:statement
CALL `synex_migrate_018_character_slot_reuse`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_018_character_slot_reuse`;
