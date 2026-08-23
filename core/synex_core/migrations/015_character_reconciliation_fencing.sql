DROP PROCEDURE IF EXISTS `synex_migrate_015_character_reconciliation_fencing`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_015_character_reconciliation_fencing`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_character_deletion_plans'
            AND `COLUMN_NAME` = 'attempt_count'
    ) THEN
        ALTER TABLE `synex_character_deletion_plans`
            ADD COLUMN `attempt_count` INT UNSIGNED NOT NULL DEFAULT 0 AFTER `version`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_character_deletion_plans'
            AND `COLUMN_NAME` = 'last_attempt_at'
    ) THEN
        ALTER TABLE `synex_character_deletion_plans`
            ADD COLUMN `last_attempt_at` DATETIME(6) NULL AFTER `attempt_count`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_character_deletion_plans'
            AND `COLUMN_NAME` = 'next_attempt_at'
    ) THEN
        ALTER TABLE `synex_character_deletion_plans`
            ADD COLUMN `next_attempt_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
            AFTER `last_attempt_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_character_deletion_plans'
            AND `COLUMN_NAME` = 'lease_fencing_token'
    ) THEN
        ALTER TABLE `synex_character_deletion_plans`
            ADD COLUMN `lease_fencing_token` BIGINT UNSIGNED NULL AFTER `next_attempt_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_character_deletion_plans'
            AND `INDEX_NAME` = 'idx_character_deletion_plans_due'
    ) THEN
        ALTER TABLE `synex_character_deletion_plans`
            ADD KEY `idx_character_deletion_plans_due`
                (`state`, `next_attempt_at`, `created_at`, `id`);
    END IF;
END;

-- synex:statement
CALL `synex_migrate_015_character_reconciliation_fencing`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_015_character_reconciliation_fencing`;
