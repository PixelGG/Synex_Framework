DROP PROCEDURE IF EXISTS `synex_migrate_021_worker_queue_scalability`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_021_worker_queue_scalability`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `COLUMN_NAME` = 'response_compaction_at'
    ) THEN
        ALTER TABLE `synex_idempotency_keys`
            ADD COLUMN `response_compaction_at` DATETIME(6) NULL AFTER `completed_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `COLUMN_NAME` = 'response_compaction_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'YES'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND COALESCE(`EXTRA`, '') = ''
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 021 response compaction marker verification failed';
    END IF;

    UPDATE `synex_idempotency_keys`
    SET `response_compaction_at` = COALESCE(`completed_at`, `expires_at`)
    WHERE `state` = 'completed' AND `response_json` IS NULL
        AND `response_compaction_at` IS NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
    ) THEN
        ALTER TABLE `synex_idempotency_keys`
            ADD KEY `idx_idempotency_response_compaction`
                (`state`, `response_compaction_at`, `expires_at`, `namespace`, `idempotency_key`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
    ) <> 5 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND (`NON_UNIQUE` <> 1 OR UPPER(`INDEX_TYPE`) <> 'BTREE'
                OR `SUB_PART` IS NOT NULL OR COALESCE(`COLLATION`, '') <> 'A')
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND `SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'response_compaction_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND `SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'expires_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND `SEQ_IN_INDEX` = 4 AND `COLUMN_NAME` = 'namespace'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_keys'
            AND `INDEX_NAME` = 'idx_idempotency_response_compaction'
            AND `SEQ_IN_INDEX` = 5 AND `COLUMN_NAME` = 'idempotency_key'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 021 response compaction index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
    ) THEN
        ALTER TABLE `synex_sagas`
            ADD KEY `idx_sagas_state_updated` (`state`, `updated_at`, `id`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
    ) <> 3 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
            AND (`NON_UNIQUE` <> 1 OR UPPER(`INDEX_TYPE`) <> 'BTREE'
                OR `SUB_PART` IS NOT NULL OR COALESCE(`COLLATION`, '') <> 'A')
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
            AND `SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'updated_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sagas'
            AND `INDEX_NAME` = 'idx_sagas_state_updated'
            AND `SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 021 saga candidate index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD KEY `idx_outbox_compact_published`
                (`state`, `payload_compacted_at`, `published_at`, `id`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
    ) <> 4 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
            AND (`NON_UNIQUE` <> 1 OR UPPER(`INDEX_TYPE`) <> 'BTREE'
                OR `SUB_PART` IS NOT NULL OR COALESCE(`COLLATION`, '') <> 'A')
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
            AND `SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'payload_compacted_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
            AND `SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'published_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_published'
            AND `SEQ_IN_INDEX` = 4 AND `COLUMN_NAME` = 'id'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 021 published outbox index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
    ) THEN
        ALTER TABLE `synex_outbox`
            ADD KEY `idx_outbox_compact_dead`
                (`state`, `payload_compacted_at`, `available_at`, `id`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
    ) <> 4 OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
            AND (`NON_UNIQUE` <> 1 OR UPPER(`INDEX_TYPE`) <> 'BTREE'
                OR `SUB_PART` IS NOT NULL OR COALESCE(`COLLATION`, '') <> 'A')
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
            AND `SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'payload_compacted_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
            AND `SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'available_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_outbox'
            AND `INDEX_NAME` = 'idx_outbox_compact_dead'
            AND `SEQ_IN_INDEX` = 4 AND `COLUMN_NAME` = 'id'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 021 dead outbox index verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_021_worker_queue_scalability`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_021_worker_queue_scalability`;
