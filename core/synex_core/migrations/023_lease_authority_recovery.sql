DROP PROCEDURE IF EXISTS `synex_migrate_023_lease_authority_recovery`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_023_lease_authority_recovery`()
BEGIN
    DECLARE `normalized_generation` LONGTEXT DEFAULT NULL;
    DECLARE `expected_generation` LONGTEXT DEFAULT
        'casewhenleftlease_name,8=''session:''then''session''whenleftlease_name,10=''admission:''then''admission''elsenullend';

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'terminal_compaction_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'YES' AND COALESCE(`EXTRA`, '') = ''
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 023 requires verified terminal lease eligibility';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_authority_kind'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD COLUMN `lease_authority_kind` VARCHAR(10)
                CHARACTER SET ascii COLLATE ascii_bin
                GENERATED ALWAYS AS (
                    CASE
                        WHEN LEFT(`lease_name`, 8) = 'session:' THEN 'session'
                        WHEN LEFT(`lease_name`, 10) = 'admission:' THEN 'admission'
                        ELSE NULL
                    END
                ) STORED AFTER `lease_domain_kind`;
    END IF;

    SET `normalized_generation` = NULL;
    SELECT LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        REPLACE(REPLACE(REPLACE(REPLACE(`GENERATION_EXPRESSION`, '`', ''), ' ', ''),
        CHAR(9), ''), CHAR(10), ''), CHAR(13), ''), '(', ''), ')', ''),
        '_utf8mb4', ''), '_utf8mb3', ''), '_utf8', ''), '_ascii', ''), '_latin1', ''))
        INTO `normalized_generation`
        FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_authority_kind'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 10
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'YES'
            AND UPPER(`EXTRA`) LIKE '%STORED GENERATED%';

    IF `normalized_generation` IS NULL
        OR `normalized_generation` <> `expected_generation` THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 023 lease authority definition verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_authority_expiry`
                (`lease_authority_kind`, `terminal_compaction_at`, `expires_at`, `lease_name`);
    END IF;

    IF NOT (
        EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
                AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
                AND `COLUMN_NAME` = 'lease_authority_kind'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
                AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
                AND `COLUMN_NAME` = 'terminal_compaction_at'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
                AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
                AND `COLUMN_NAME` = 'expires_at'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
                AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 4
                AND `COLUMN_NAME` = 'lease_name'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND NOT EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
                AND `INDEX_NAME` = 'idx_cluster_leases_authority_expiry'
                AND `SEQ_IN_INDEX` > 4
        )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 023 authority recovery index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
    ) THEN
        ALTER TABLE `synex_sessions`
            ADD KEY `idx_sessions_open_heartbeat_expiry`
                (`closed_at`, `last_seen_at`, `id`, `server_instance_id`);
    END IF;

    IF NOT (
        EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
                AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
                AND `COLUMN_NAME` = 'closed_at'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
                AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
                AND `COLUMN_NAME` = 'last_seen_at'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
                AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
                AND `COLUMN_NAME` = 'id'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
                AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
                AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 4
                AND `COLUMN_NAME` = 'server_instance_id'
                AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
        ) AND NOT EXISTS (
            SELECT 1 FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
                AND `INDEX_NAME` = 'idx_sessions_open_heartbeat_expiry'
                AND `SEQ_IN_INDEX` > 4
        )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 023 stale session queue index verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_023_lease_authority_recovery`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_023_lease_authority_recovery`;
