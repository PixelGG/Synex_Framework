DROP PROCEDURE IF EXISTS `synex_migrate_026_lease_authority_owner_index`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_026_lease_authority_owner_index`()
BEGIN
    DECLARE `index_metadata_usable` TINYINT DEFAULT 1;
    DECLARE `index_probe_count` BIGINT DEFAULT NULL;
    DECLARE `index_probe_ok` TINYINT DEFAULT 0;
    DECLARE `index_usability_capability_count` BIGINT DEFAULT 0;
    DECLARE `index_usability_column` VARCHAR(16) DEFAULT NULL;
    DECLARE `normalized_generation` LONGTEXT DEFAULT NULL;
    DECLARE `usable_index_rows` BIGINT DEFAULT NULL;
    DECLARE `expected_generation` LONGTEXT DEFAULT
        'casewhenleftlease_name,8=''session:''then''session''whenleftlease_name,10=''admission:''then''admission''elsenullend';

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_authority_kind'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 10
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'YES'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND UPPER(`EXTRA`) LIKE '%STORED GENERATED%'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'terminal_compaction_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'YES'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'owner_id'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 96
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_name'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 96
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 026 requires verified lease authority columns';
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
            SET MESSAGE_TEXT = 'synex migration 026 lease authority definition verification failed';
    END IF;

    SELECT COUNT(*), MAX(UPPER(`COLUMN_NAME`))
        INTO `index_usability_capability_count`, `index_usability_column`
        FROM `information_schema`.`COLUMNS`
        WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
            AND UPPER(`TABLE_NAME`) = 'STATISTICS'
            AND UPPER(`COLUMN_NAME`) IN ('IGNORED', 'IS_VISIBLE');

    IF `index_usability_capability_count` <> 1
        OR `index_usability_column` NOT IN ('IGNORED', 'IS_VISIBLE') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 026 index usability metadata verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_authority_owner`
                (`lease_authority_kind`, `terminal_compaction_at`, `owner_id`, `lease_name`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'lease_authority_kind'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'terminal_compaction_at'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'owner_id'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_authority_owner'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 4
            AND `COLUMN_NAME` = 'lease_name'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 026 lease authority owner index verification failed';
    END IF;

    IF `index_usability_column` = 'IGNORED' THEN
        SET @synex_026_index_usability_sql =
            'SELECT COUNT(*) INTO @synex_026_usable_index_rows
             FROM `information_schema`.`STATISTICS`
             WHERE `TABLE_SCHEMA` = DATABASE()
               AND `TABLE_NAME` = ''synex_cluster_leases''
               AND `INDEX_NAME` = ''idx_cluster_leases_authority_owner''
               AND UPPER(COALESCE(`IGNORED`, ''YES'')) = ''NO''';
    ELSEIF `index_usability_column` = 'IS_VISIBLE' THEN
        SET @synex_026_index_usability_sql =
            'SELECT COUNT(*) INTO @synex_026_usable_index_rows
             FROM `information_schema`.`STATISTICS`
             WHERE `TABLE_SCHEMA` = DATABASE()
               AND `TABLE_NAME` = ''synex_cluster_leases''
               AND `INDEX_NAME` = ''idx_cluster_leases_authority_owner''
               AND UPPER(COALESCE(`IS_VISIBLE`, ''NO'')) = ''YES''';
    END IF;

    SET @synex_026_usable_index_rows = NULL;
    PREPARE `synex_026_index_usability` FROM @synex_026_index_usability_sql;
    EXECUTE `synex_026_index_usability`;
    DEALLOCATE PREPARE `synex_026_index_usability`;
    SET `usable_index_rows` = @synex_026_usable_index_rows;
    SET @synex_026_usable_index_rows = NULL;
    SET @synex_026_index_usability_sql = NULL;

    IF `usable_index_rows` IS NULL OR `usable_index_rows` <> 4 THEN
        SET `index_metadata_usable` = 0;
    END IF;

    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET `index_probe_ok` = 0;
        SET `index_probe_ok` = 1;
        SELECT COUNT(`lease_name`) INTO `index_probe_count`
        FROM `synex_cluster_leases`
            FORCE INDEX (`idx_cluster_leases_authority_owner`)
        WHERE `lease_authority_kind` = '__probe__';
    END;

    IF `index_metadata_usable` <> 1
        OR `index_probe_ok` <> 1
        OR `index_probe_count` IS NULL
        OR `index_probe_count` <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 026 lease authority owner index usability verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_026_lease_authority_owner_index`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_026_lease_authority_owner_index`;
