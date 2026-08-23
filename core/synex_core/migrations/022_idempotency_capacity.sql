CREATE TABLE IF NOT EXISTS `synex_idempotency_capacity` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `global_limit` INT UNSIGNED NOT NULL DEFAULT 1000000,
    `owner_limit` INT UNSIGNED NOT NULL DEFAULT 100000,
    `namespace_limit` INT UNSIGNED NOT NULL DEFAULT 10000,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_idempotency_capacity_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_idempotency_capacity_global_limit` CHECK (`global_limit` > 0),
    CONSTRAINT `chk_idempotency_capacity_owner_limit`
        CHECK (`owner_limit` > 0 AND `owner_limit` <= `global_limit`),
    CONSTRAINT `chk_idempotency_capacity_namespace_limit`
        CHECK (`namespace_limit` > 0 AND `namespace_limit` <= `owner_limit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_idempotency_owner_capacity` (
    `owner_resource` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`owner_resource`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_idempotency_namespace_capacity` (
    `namespace` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`namespace`),
    KEY `idx_idempotency_namespace_capacity_owner` (`owner_resource`),
    CONSTRAINT `fk_idempotency_namespace_capacity_owner`
        FOREIGN KEY (`owner_resource`)
        REFERENCES `synex_idempotency_owner_capacity` (`owner_resource`)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_022_idempotency_capacity`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_022_idempotency_capacity`()
BEGIN
    DECLARE v_key_count BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_enforced_metadata TINYINT UNSIGNED DEFAULT 0;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_idempotency_capacity',
                'synex_idempotency_owner_capacity',
                'synex_idempotency_namespace_capacity'
            )
            AND `TABLE_TYPE` = 'BASE TABLE'
            AND UPPER(`ENGINE`) = 'INNODB'
            AND `TABLE_COLLATION` = 'utf8mb4_unicode_ci'
    ) <> 3 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 capacity table verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
    ) <> 6 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'singleton_id' AND LOWER(`DATA_TYPE`) = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'entry_count' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'global_limit' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 1000000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'owner_limit' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 100000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'namespace_limit' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 10000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 global capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
            AND `COLUMN_NAME` = 'owner_resource' AND LOWER(`DATA_TYPE`) = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 96 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
            AND `COLUMN_DEFAULT` IS NULL AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
            AND `COLUMN_NAME` = 'entry_count' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 owner capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `COLUMN_NAME` = 'namespace' AND LOWER(`DATA_TYPE`) = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 96 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
            AND `COLUMN_DEFAULT` IS NULL AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `COLUMN_NAME` = 'owner_resource' AND LOWER(`DATA_TYPE`) = 'varchar'
            AND `CHARACTER_MAXIMUM_LENGTH` = 96 AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO'
            AND `COLUMN_DEFAULT` IS NULL AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `COLUMN_NAME` = 'entry_count' AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 namespace capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'singleton_id' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'owner_resource' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
    ) <> 2 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'namespace' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `INDEX_NAME` = 'idx_idempotency_namespace_capacity_owner'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'owner_resource' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 capacity index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `CONSTRAINT_NAME` = 'fk_idempotency_namespace_capacity_owner'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`REFERENTIAL_CONSTRAINTS` AS `reference`
        INNER JOIN `information_schema`.`KEY_COLUMN_USAGE` AS `usage`
            ON `usage`.`CONSTRAINT_SCHEMA` = `reference`.`CONSTRAINT_SCHEMA`
            AND `usage`.`CONSTRAINT_NAME` = `reference`.`CONSTRAINT_NAME`
            AND `usage`.`TABLE_NAME` = `reference`.`TABLE_NAME`
        WHERE `reference`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `reference`.`TABLE_NAME` = 'synex_idempotency_namespace_capacity'
            AND `reference`.`CONSTRAINT_NAME` = 'fk_idempotency_namespace_capacity_owner'
            AND `reference`.`REFERENCED_TABLE_NAME` = 'synex_idempotency_owner_capacity'
            AND `reference`.`UNIQUE_CONSTRAINT_SCHEMA` = DATABASE()
            AND `reference`.`UPDATE_RULE` = 'RESTRICT' AND `reference`.`DELETE_RULE` = 'RESTRICT'
            AND `usage`.`TABLE_SCHEMA` = DATABASE()
            AND `usage`.`COLUMN_NAME` = 'owner_resource'
            AND `usage`.`REFERENCED_TABLE_SCHEMA` = DATABASE()
            AND `usage`.`REFERENCED_COLUMN_NAME` = 'owner_resource'
            AND `usage`.`ORDINAL_POSITION` = 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 capacity foreign key verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
    ) <> 5 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_singleton'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_global_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_owner_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_idempotency_capacity'
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_namespace_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_singleton'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'singleton_id=1'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_global_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'global_limit>0'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_owner_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '')
                = 'owner_limit>0andowner_limit<=global_limit'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_idempotency_capacity_namespace_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '')
                = 'namespace_limit>0andnamespace_limit<=owner_limit'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_owner_capacity'
    ) <> 1 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_idempotency_namespace_capacity'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 capacity check verification failed';
    END IF;

    SELECT COUNT(*) INTO v_enforced_metadata
    FROM `information_schema`.`COLUMNS`
    WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
        AND UPPER(`TABLE_NAME`) = 'TABLE_CONSTRAINTS'
        AND UPPER(`COLUMN_NAME`) = 'ENFORCED';
    IF v_enforced_metadata > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 check enforcement metadata is ambiguous';
    END IF;
    IF v_enforced_metadata = 1 THEN
        SET @synex_migrate_022_enforced_checks = NULL;
        SET @synex_migrate_022_enforced_sql =
            'SELECT COUNT(*) INTO @synex_migrate_022_enforced_checks '
            'FROM information_schema.TABLE_CONSTRAINTS '
            'WHERE CONSTRAINT_SCHEMA = DATABASE() '
            'AND TABLE_NAME = ''synex_idempotency_capacity'' '
            'AND CONSTRAINT_TYPE = ''CHECK'' '
            'AND CONSTRAINT_NAME IN (''chk_idempotency_capacity_singleton'', '
            '''chk_idempotency_capacity_global_limit'', '
            '''chk_idempotency_capacity_owner_limit'', '
            '''chk_idempotency_capacity_namespace_limit'') '
            'AND UPPER(COALESCE(ENFORCED, ''NO'')) = ''YES''';
        PREPARE `synex_migrate_022_enforced_statement`
            FROM @synex_migrate_022_enforced_sql;
        EXECUTE `synex_migrate_022_enforced_statement`;
        DEALLOCATE PREPARE `synex_migrate_022_enforced_statement`;
        IF COALESCE(@synex_migrate_022_enforced_checks, 0) <> 4 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'synex migration 022 capacity checks are not enforced';
        END IF;
        SET @synex_migrate_022_enforced_checks = NULL;
        SET @synex_migrate_022_enforced_sql = NULL;
    END IF;

    INSERT INTO `synex_idempotency_capacity`
        (`singleton_id`, `entry_count`, `global_limit`, `owner_limit`, `namespace_limit`)
    VALUES (1, 0, 1000000, 100000, 10000)
    ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);

    SELECT COUNT(*) INTO v_key_count FROM `synex_idempotency_keys`;
    IF v_key_count > 4294967295 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 existing key count exceeds counter range';
    END IF;

    DELETE FROM `synex_idempotency_namespace_capacity`;
    DELETE FROM `synex_idempotency_owner_capacity`;

    INSERT INTO `synex_idempotency_owner_capacity` (`owner_resource`, `entry_count`)
    SELECT SUBSTRING_INDEX(`namespace`, ':', 1), CAST(COUNT(*) AS UNSIGNED)
    FROM `synex_idempotency_keys`
    GROUP BY SUBSTRING_INDEX(`namespace`, ':', 1);

    INSERT INTO `synex_idempotency_namespace_capacity`
        (`namespace`, `owner_resource`, `entry_count`)
    SELECT `namespace`, SUBSTRING_INDEX(`namespace`, ':', 1), CAST(COUNT(*) AS UNSIGNED)
    FROM `synex_idempotency_keys`
    GROUP BY `namespace`, SUBSTRING_INDEX(`namespace`, ':', 1);

    UPDATE `synex_idempotency_capacity`
    SET `entry_count` = CAST(v_key_count AS UNSIGNED)
    WHERE `singleton_id` = 1;

    IF (
        SELECT COUNT(*) FROM `synex_idempotency_capacity`
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `synex_idempotency_capacity`
        WHERE `singleton_id` = 1 AND `entry_count` = v_key_count
            AND `global_limit` > 0 AND `owner_limit` > 0 AND `namespace_limit` > 0
            AND `namespace_limit` <= `owner_limit` AND `owner_limit` <= `global_limit`
    ) OR (
        SELECT COALESCE(SUM(`entry_count`), 0)
        FROM `synex_idempotency_owner_capacity`
    ) <> v_key_count OR (
        SELECT COALESCE(SUM(`entry_count`), 0)
        FROM `synex_idempotency_namespace_capacity`
    ) <> v_key_count OR EXISTS (
        SELECT 1
        FROM (
            SELECT SUBSTRING_INDEX(`namespace`, ':', 1) AS `owner_resource`,
                COUNT(*) AS `entry_count`
            FROM `synex_idempotency_keys`
            GROUP BY SUBSTRING_INDEX(`namespace`, ':', 1)
        ) AS `actual`
        LEFT JOIN `synex_idempotency_owner_capacity` AS `counter`
            ON `counter`.`owner_resource` = `actual`.`owner_resource`
        WHERE `counter`.`owner_resource` IS NULL
            OR `counter`.`entry_count` <> `actual`.`entry_count`
    ) OR EXISTS (
        SELECT 1 FROM `synex_idempotency_owner_capacity` AS `counter`
        LEFT JOIN (
            SELECT SUBSTRING_INDEX(`namespace`, ':', 1) AS `owner_resource`
            FROM `synex_idempotency_keys`
            GROUP BY SUBSTRING_INDEX(`namespace`, ':', 1)
        ) AS `actual` ON `actual`.`owner_resource` = `counter`.`owner_resource`
        WHERE `actual`.`owner_resource` IS NULL
    ) OR EXISTS (
        SELECT 1
        FROM (
            SELECT `namespace`, SUBSTRING_INDEX(`namespace`, ':', 1) AS `owner_resource`,
                COUNT(*) AS `entry_count`
            FROM `synex_idempotency_keys`
            GROUP BY `namespace`, SUBSTRING_INDEX(`namespace`, ':', 1)
        ) AS `actual`
        LEFT JOIN `synex_idempotency_namespace_capacity` AS `counter`
            ON `counter`.`namespace` = `actual`.`namespace`
        WHERE `counter`.`namespace` IS NULL
            OR `counter`.`owner_resource` <> `actual`.`owner_resource`
            OR `counter`.`entry_count` <> `actual`.`entry_count`
    ) OR EXISTS (
        SELECT 1 FROM `synex_idempotency_namespace_capacity` AS `counter`
        LEFT JOIN `synex_idempotency_keys` AS `existing`
            ON `existing`.`namespace` = `counter`.`namespace`
        WHERE `existing`.`id` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 022 capacity backfill verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_022_idempotency_capacity`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_022_idempotency_capacity`;
