CREATE TABLE IF NOT EXISTS `synex_cluster_lease_capacity` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `global_limit` INT UNSIGNED NOT NULL DEFAULT 1000000,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_cluster_lease_capacity_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_cluster_lease_capacity_global_limit` CHECK (`global_limit` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_cluster_lease_kind_capacity` (
    `lease_capacity_kind` VARCHAR(9) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `kind_limit` INT UNSIGNED NOT NULL,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`lease_capacity_kind`),
    CONSTRAINT `chk_cluster_lease_kind_capacity_kind`
        CHECK (`lease_capacity_kind` IN ('session', 'admission', 'saga', 'character', 'other')),
    CONSTRAINT `chk_cluster_lease_kind_capacity_limit` CHECK (`kind_limit` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_025_cluster_lease_capacity`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_025_cluster_lease_capacity`()
BEGIN
    DECLARE `normalized_generation` LONGTEXT DEFAULT NULL;
    DECLARE `expected_generation` LONGTEXT DEFAULT
        'casewhenlease_name=''schema_migrations''thennullwhenleftlease_name,8=''session:''then''session''whenleftlease_name,10=''admission:''then''admission''whenleftlease_name,5=''saga:''then''saga''whenleftlease_name,17=''character-delete:''then''character''else''other''end';
    DECLARE `v_lease_count` BIGINT UNSIGNED DEFAULT 0;
    DECLARE `v_enforced_metadata` TINYINT UNSIGNED DEFAULT 0;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_cluster_lease_capacity',
                'synex_cluster_lease_kind_capacity'
            )
            AND `TABLE_TYPE` = 'BASE TABLE'
            AND UPPER(`ENGINE`) = 'INNODB'
            AND `TABLE_COLLATION` = 'utf8mb4_unicode_ci'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 capacity table verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `COLUMN_NAME` = 'singleton_id'
            AND LOWER(`DATA_TYPE`) = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `COLUMN_NAME` = 'global_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 1000000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 global capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `COLUMN_NAME` = 'lease_capacity_kind'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 9
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `COLUMN_NAME` = 'kind_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 kind capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'singleton_id'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'lease_capacity_kind'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 capacity index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_capacity_singleton'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_capacity'
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_capacity_global_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_capacity_singleton'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'singleton_id=1'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_capacity_global_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'global_limit>0'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_kind_capacity_kind'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_cluster_lease_kind_capacity'
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_kind_capacity_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_kind_capacity_kind'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                    CHAR(9), ''), CHAR(10), ''), CHAR(13), ''),
                '_utf8mb4', ''), '_utf8mb3', ''), '_utf8', ''),
                '_ascii', ''), '_latin1', '')
                = 'lease_capacity_kindin''session'',''admission'',''saga'',''character'',''other'''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_cluster_lease_kind_capacity_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'kind_limit>0'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 capacity constraint verification failed';
    END IF;

    SELECT COUNT(*) INTO `v_enforced_metadata`
    FROM `information_schema`.`COLUMNS`
    WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
        AND UPPER(`TABLE_NAME`) = 'TABLE_CONSTRAINTS'
        AND UPPER(`COLUMN_NAME`) = 'ENFORCED';
    IF `v_enforced_metadata` > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 check enforcement metadata is ambiguous';
    END IF;
    IF `v_enforced_metadata` = 1 THEN
        SET @`synex_migrate_025_enforced_checks` = NULL;
        SET @`synex_migrate_025_enforced_sql` =
            'SELECT COUNT(*) INTO @synex_migrate_025_enforced_checks '
            'FROM information_schema.TABLE_CONSTRAINTS '
            'WHERE CONSTRAINT_SCHEMA = DATABASE() AND CONSTRAINT_TYPE = ''CHECK'' '
            'AND ((TABLE_NAME = ''synex_cluster_lease_capacity'' '
            'AND CONSTRAINT_NAME IN (''chk_cluster_lease_capacity_singleton'', '
            '''chk_cluster_lease_capacity_global_limit'')) '
            'OR (TABLE_NAME = ''synex_cluster_lease_kind_capacity'' '
            'AND CONSTRAINT_NAME IN (''chk_cluster_lease_kind_capacity_kind'', '
            '''chk_cluster_lease_kind_capacity_limit''))) '
            'AND UPPER(COALESCE(ENFORCED, ''NO'')) = ''YES''';
        PREPARE `synex_migrate_025_enforced_statement`
            FROM @`synex_migrate_025_enforced_sql`;
        EXECUTE `synex_migrate_025_enforced_statement`;
        DEALLOCATE PREPARE `synex_migrate_025_enforced_statement`;
        IF COALESCE(@`synex_migrate_025_enforced_checks`, 0) <> 4 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'synex migration 025 capacity checks are not enforced';
        END IF;
        SET @`synex_migrate_025_enforced_checks` = NULL;
        SET @`synex_migrate_025_enforced_sql` = NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_authority_kind'
            AND UPPER(`EXTRA`) LIKE '%STORED GENERATED%'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 requires verified lease authority recovery';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_capacity_kind'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD COLUMN `lease_capacity_kind` VARCHAR(9)
                CHARACTER SET ascii COLLATE ascii_bin
                GENERATED ALWAYS AS (
                    CASE
                        WHEN `lease_name` = 'schema_migrations' THEN NULL
                        WHEN LEFT(`lease_name`, 8) = 'session:' THEN 'session'
                        WHEN LEFT(`lease_name`, 10) = 'admission:' THEN 'admission'
                        WHEN LEFT(`lease_name`, 5) = 'saga:' THEN 'saga'
                        WHEN LEFT(`lease_name`, 17) = 'character-delete:' THEN 'character'
                        ELSE 'other'
                    END
                ) STORED AFTER `lease_authority_kind`;
    END IF;

    SET `normalized_generation` = NULL;
    SELECT LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        REPLACE(REPLACE(REPLACE(REPLACE(`GENERATION_EXPRESSION`, '`', ''), ' ', ''),
        CHAR(9), ''), CHAR(10), ''), CHAR(13), ''), '(', ''), ')', ''),
        '_utf8mb4', ''), '_utf8mb3', ''), '_utf8', ''), '_ascii', ''), '_latin1', ''))
        INTO `normalized_generation`
        FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_capacity_kind'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 9
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'YES'
            AND UPPER(`EXTRA`) LIKE '%STORED GENERATED%';

    IF `normalized_generation` IS NULL
        OR `normalized_generation` <> `expected_generation` THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 lease capacity classification verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_capacity_kind'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_capacity_kind`
                (`lease_capacity_kind`, `lease_name`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_capacity_kind'
    ) <> 2 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_capacity_kind'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'lease_capacity_kind'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_capacity_kind'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'lease_name'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 lease capacity index verification failed';
    END IF;

    INSERT INTO `synex_cluster_lease_capacity`
        (`singleton_id`, `entry_count`, `global_limit`)
    VALUES (1, 0, 1000000)
    ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);

    INSERT INTO `synex_cluster_lease_kind_capacity`
        (`lease_capacity_kind`, `entry_count`, `kind_limit`)
    VALUES
        ('session', 0, 500000),
        ('admission', 0, 250000),
        ('saga', 0, 250000),
        ('character', 0, 100000),
        ('other', 0, 100000)
    ON DUPLICATE KEY UPDATE
        `lease_capacity_kind` = VALUES(`lease_capacity_kind`);

    IF (
        SELECT COUNT(*) FROM `synex_cluster_lease_capacity`
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `synex_cluster_lease_capacity`
        WHERE `singleton_id` = 1 AND `global_limit` > 0
    ) OR (
        SELECT COUNT(*) FROM `synex_cluster_lease_kind_capacity`
    ) <> 5 OR EXISTS (
        SELECT 1 FROM `synex_cluster_lease_kind_capacity`
        WHERE `lease_capacity_kind` NOT IN
            ('session', 'admission', 'saga', 'character', 'other')
            OR `kind_limit` = 0
    ) OR EXISTS (
        SELECT 1 FROM `synex_cluster_lease_kind_capacity` AS `kind_capacity`
        INNER JOIN `synex_cluster_lease_capacity` AS `global_capacity`
            ON `global_capacity`.`singleton_id` = 1
        WHERE `kind_capacity`.`kind_limit` > `global_capacity`.`global_limit`
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 capacity authority verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `synex_cluster_leases`
        WHERE (`lease_name` = 'schema_migrations' AND `lease_capacity_kind` IS NOT NULL)
            OR (`lease_name` <> 'schema_migrations' AND `lease_capacity_kind` IS NULL)
            OR (`lease_capacity_kind` IS NOT NULL AND `lease_capacity_kind` NOT IN
                ('session', 'admission', 'saga', 'character', 'other'))
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 lease classification consistency failed';
    END IF;

    SELECT COUNT(*) INTO `v_lease_count`
    FROM `synex_cluster_leases`
    WHERE `lease_capacity_kind` IS NOT NULL;
    IF `v_lease_count` > 4294967295 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 existing lease count exceeds counter range';
    END IF;
    IF EXISTS (
        SELECT `lease_capacity_kind`
        FROM `synex_cluster_leases`
        WHERE `lease_capacity_kind` IS NOT NULL
        GROUP BY `lease_capacity_kind`
        HAVING COUNT(*) > 4294967295
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 lease kind count exceeds counter range';
    END IF;

    UPDATE `synex_cluster_lease_kind_capacity` AS `counter`
    LEFT JOIN (
        SELECT `lease_capacity_kind`, COUNT(*) AS `entry_count`
        FROM `synex_cluster_leases`
        WHERE `lease_capacity_kind` IS NOT NULL
        GROUP BY `lease_capacity_kind`
    ) AS `actual`
        ON `actual`.`lease_capacity_kind` = `counter`.`lease_capacity_kind`
    SET `counter`.`entry_count` = CAST(COALESCE(`actual`.`entry_count`, 0) AS UNSIGNED);

    UPDATE `synex_cluster_lease_capacity`
    SET `entry_count` = CAST(`v_lease_count` AS UNSIGNED)
    WHERE `singleton_id` = 1;

    IF NOT EXISTS (
        SELECT 1 FROM `synex_cluster_lease_capacity`
        WHERE `singleton_id` = 1 AND `entry_count` = `v_lease_count`
            AND `global_limit` > 0
    ) OR (
        SELECT COALESCE(SUM(`entry_count`), 0)
        FROM `synex_cluster_lease_kind_capacity`
    ) <> `v_lease_count` OR EXISTS (
        SELECT 1
        FROM `synex_cluster_lease_kind_capacity` AS `counter`
        LEFT JOIN (
            SELECT `lease_capacity_kind`, COUNT(*) AS `entry_count`
            FROM `synex_cluster_leases`
            WHERE `lease_capacity_kind` IS NOT NULL
            GROUP BY `lease_capacity_kind`
        ) AS `actual`
            ON `actual`.`lease_capacity_kind` = `counter`.`lease_capacity_kind`
        WHERE `counter`.`entry_count` <> COALESCE(`actual`.`entry_count`, 0)
    ) OR EXISTS (
        SELECT 1
        FROM `synex_cluster_leases` AS `lease`
        LEFT JOIN `synex_cluster_lease_kind_capacity` AS `counter`
            ON `counter`.`lease_capacity_kind` = `lease`.`lease_capacity_kind`
        WHERE `lease`.`lease_capacity_kind` IS NOT NULL
            AND `counter`.`lease_capacity_kind` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 025 capacity backfill verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_025_cluster_lease_capacity`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_025_cluster_lease_capacity`;
