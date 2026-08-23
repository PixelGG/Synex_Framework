DROP PROCEDURE IF EXISTS `synex_migrate_014_runtime_owner_attribution`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_014_runtime_owner_attribution`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `COLUMN_NAME` = 'owner_resource'
    ) THEN
        ALTER TABLE `synex_sagas`
            ADD COLUMN `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL
            AFTER `public_id`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_owner_type_correlation'
    ) THEN
        ALTER TABLE `synex_sagas`
            ADD UNIQUE KEY `uq_sagas_owner_type_correlation`
                (`owner_resource`, `saga_type`, `correlation_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_owner_type_correlation'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'owner_resource'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_owner_type_correlation'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'saga_type'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_owner_type_correlation'
            AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'correlation_id'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_owner_type_correlation'
            AND `SEQ_IN_INDEX` > 3
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 014 owner-scoped saga uniqueness verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'uq_sagas_type_correlation'
    ) THEN
        ALTER TABLE `synex_sagas`
            DROP INDEX `uq_sagas_type_correlation`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `COLUMN_NAME` = 'producer_resource'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD COLUMN `producer_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL
            AFTER `event_id`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `COLUMN_NAME` = 'last_error_code'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD COLUMN `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL
            AFTER `locked_until`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `COLUMN_NAME` = 'payload_compacted_at'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD COLUMN `payload_compacted_at` DATETIME(6) NULL
            AFTER `published_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_terminal_compaction'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD KEY `idx_outbox_terminal_compaction`
                (`state`, `payload_compacted_at`, `id`);
    END IF;
END;

-- synex:statement
CALL `synex_migrate_014_runtime_owner_attribution`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_014_runtime_owner_attribution`;
