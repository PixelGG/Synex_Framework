DROP PROCEDURE IF EXISTS `synex_migrate_020_terminal_lease_eligibility`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_020_terminal_lease_eligibility`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'terminal_compaction_at'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD COLUMN `terminal_compaction_at` DATETIME(6) NULL AFTER `expires_at`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'terminal_compaction_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'YES' AND COALESCE(`EXTRA`, '') = ''
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 020 terminal compaction column verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_terminal_compaction'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_terminal_compaction`
                (`terminal_compaction_at`, `lease_name`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_terminal_compaction'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'terminal_compaction_at'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_terminal_compaction'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'lease_name'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_terminal_compaction'
            AND `SEQ_IN_INDEX` > 2
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 020 terminal compaction index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_character_open'
    ) THEN
        ALTER TABLE `synex_sessions`
            ADD KEY `idx_sessions_character_open` (`character_id`, `closed_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_character_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'character_id'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_character_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'closed_at'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_character_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'id'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_character_open' AND `SEQ_IN_INDEX` > 3
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 020 open character session index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open'
    ) THEN
        ALTER TABLE `synex_sessions`
            ADD KEY `idx_sessions_user_open`
                (`user_id`, `closed_at`, `connected_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'user_id'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'closed_at'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'connected_at'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 4
            AND `COLUMN_NAME` = 'id'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_user_open' AND `SEQ_IN_INDEX` > 4
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 020 open user session index verification failed';
    END IF;

    UPDATE `synex_cluster_leases` AS `lease`
    INNER JOIN `synex_sagas` AS `saga`
        ON `lease`.`lease_name` = CONCAT('saga:', `saga`.`public_id`)
    SET `lease`.`owner_id` = 'terminal',
        `lease`.`fencing_token` = CASE
            WHEN `lease`.`fencing_token` < 18446744073709551615
                THEN `lease`.`fencing_token` + 1
            ELSE `lease`.`fencing_token`
        END,
        `lease`.`expires_at` = CURRENT_TIMESTAMP(6),
        `lease`.`terminal_compaction_at` = CURRENT_TIMESTAMP(6)
    WHERE `lease`.`terminal_compaction_at` IS NULL
        AND `saga`.`state` IN ('completed', 'failed', 'cancelled');

    UPDATE `synex_cluster_leases` AS `lease`
    INNER JOIN `synex_character_deletion_plans` AS `deletion`
        ON `lease`.`lease_name` = CONCAT('character-delete:', `deletion`.`id`)
    SET `lease`.`owner_id` = 'terminal',
        `lease`.`fencing_token` = CASE
            WHEN `lease`.`fencing_token` < 18446744073709551615
                THEN `lease`.`fencing_token` + 1
            ELSE `lease`.`fencing_token`
        END,
        `lease`.`expires_at` = CURRENT_TIMESTAMP(6),
        `lease`.`terminal_compaction_at` = CURRENT_TIMESTAMP(6)
    WHERE `lease`.`terminal_compaction_at` IS NULL
        AND `deletion`.`state` IN ('completed', 'failed', 'cancelled');

    -- This migration requires a full cluster stop. Rows from a stopped runtime
    -- that are already expired cannot still own live admission authority.
    UPDATE `synex_cluster_leases`
    SET `owner_id` = 'retired',
        `fencing_token` = CASE
            WHEN `fencing_token` < 18446744073709551615
                THEN `fencing_token` + 1
            ELSE `fencing_token`
        END,
        `terminal_compaction_at` = `expires_at`
    WHERE `terminal_compaction_at` IS NULL
        AND `expires_at` <= CURRENT_TIMESTAMP(6)
        AND (`lease_name` LIKE 'session:%' OR `lease_name` LIKE 'admission:%');
END;

-- synex:statement
CALL `synex_migrate_020_terminal_lease_eligibility`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_020_terminal_lease_eligibility`;
