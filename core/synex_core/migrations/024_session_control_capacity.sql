CREATE TABLE IF NOT EXISTS `synex_session_control_capacity` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `global_limit` INT UNSIGNED NOT NULL DEFAULT 100000,
    `requester_limit` INT UNSIGNED NOT NULL DEFAULT 10000,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_session_control_capacity_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_session_control_capacity_global_limit` CHECK (`global_limit` > 0),
    CONSTRAINT `chk_session_control_capacity_requester_limit`
        CHECK (`requester_limit` > 0 AND `requester_limit` <= `global_limit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_session_control_requester_capacity` (
    `requested_by_instance_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`requested_by_instance_id`),
    CONSTRAINT `fk_session_control_requester_capacity_instance`
        FOREIGN KEY (`requested_by_instance_id`)
        REFERENCES `synex_instances` (`instance_id`)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_024_session_control_capacity`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_024_session_control_capacity`()
BEGIN
    DECLARE v_request_count BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_enforced_metadata TINYINT UNSIGNED DEFAULT 0;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_session_control_capacity',
                'synex_session_control_requester_capacity'
            )
            AND `TABLE_TYPE` = 'BASE TABLE'
            AND UPPER(`ENGINE`) = 'INNODB'
            AND `TABLE_COLLATION` = 'utf8mb4_unicode_ci'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 capacity table verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
    ) <> 5 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `COLUMN_NAME` = 'singleton_id'
            AND LOWER(`DATA_TYPE`) = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `COLUMN_NAME` = 'global_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 100000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `COLUMN_NAME` = 'requester_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 10000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 global capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `COLUMN_NAME` = 'requested_by_instance_id'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 36
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO' AND `COLUMN_DEFAULT` IS NULL
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `COLUMN_NAME` = 'updated_at' AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6 AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 requester capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'singleton_id'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'requested_by_instance_id'
            AND UPPER(`INDEX_TYPE`) = 'BTREE' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 capacity index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_singleton'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_global_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_capacity'
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_requester_limit'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_singleton'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'singleton_id=1'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_global_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'global_limit>0'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_session_control_capacity_requester_limit'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '')
                = 'requester_limit>0andrequester_limit<=global_limit'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 capacity constraint verification failed';
    END IF;

    SELECT COUNT(*) INTO v_enforced_metadata
    FROM `information_schema`.`COLUMNS`
    WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
        AND UPPER(`TABLE_NAME`) = 'TABLE_CONSTRAINTS'
        AND UPPER(`COLUMN_NAME`) = 'ENFORCED';
    IF v_enforced_metadata > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 check enforcement metadata is ambiguous';
    END IF;
    IF v_enforced_metadata = 1 THEN
        SET @synex_migrate_024_enforced_checks = NULL;
        SET @synex_migrate_024_enforced_sql =
            'SELECT COUNT(*) INTO @synex_migrate_024_enforced_checks '
            'FROM information_schema.TABLE_CONSTRAINTS '
            'WHERE CONSTRAINT_SCHEMA = DATABASE() '
            'AND TABLE_NAME = ''synex_session_control_capacity'' '
            'AND CONSTRAINT_TYPE = ''CHECK'' '
            'AND CONSTRAINT_NAME IN (''chk_session_control_capacity_singleton'', '
            '''chk_session_control_capacity_global_limit'', '
            '''chk_session_control_capacity_requester_limit'') '
            'AND UPPER(COALESCE(ENFORCED, ''NO'')) = ''YES''';
        PREPARE `synex_migrate_024_enforced_statement`
            FROM @synex_migrate_024_enforced_sql;
        EXECUTE `synex_migrate_024_enforced_statement`;
        DEALLOCATE PREPARE `synex_migrate_024_enforced_statement`;
        IF COALESCE(@synex_migrate_024_enforced_checks, 0) <> 3 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'synex migration 024 capacity checks are not enforced';
        END IF;
        SET @synex_migrate_024_enforced_checks = NULL;
        SET @synex_migrate_024_enforced_sql = NULL;
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `CONSTRAINT_NAME` = 'fk_session_control_requester_capacity_instance'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`REFERENTIAL_CONSTRAINTS` AS `reference`
        INNER JOIN `information_schema`.`KEY_COLUMN_USAGE` AS `usage`
            ON `usage`.`CONSTRAINT_SCHEMA` = `reference`.`CONSTRAINT_SCHEMA`
            AND `usage`.`CONSTRAINT_NAME` = `reference`.`CONSTRAINT_NAME`
            AND `usage`.`TABLE_NAME` = `reference`.`TABLE_NAME`
        WHERE `reference`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `reference`.`TABLE_NAME` = 'synex_session_control_requester_capacity'
            AND `reference`.`CONSTRAINT_NAME`
                = 'fk_session_control_requester_capacity_instance'
            AND `reference`.`REFERENCED_TABLE_NAME` = 'synex_instances'
            AND `reference`.`UNIQUE_CONSTRAINT_SCHEMA` = DATABASE()
            AND `reference`.`UPDATE_RULE` = 'RESTRICT'
            AND `reference`.`DELETE_RULE` = 'RESTRICT'
            AND `usage`.`COLUMN_NAME` = 'requested_by_instance_id'
            AND `usage`.`REFERENCED_TABLE_SCHEMA` = DATABASE()
            AND `usage`.`REFERENCED_COLUMN_NAME` = 'instance_id'
            AND `usage`.`ORDINAL_POSITION` = 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 capacity foreign key verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_terminal_retention'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            ADD KEY `idx_session_control_terminal_retention`
                (`state`, `completed_at`, `request_id`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_terminal_retention'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_terminal_retention'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'state' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_terminal_retention'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'completed_at' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_terminal_retention'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'request_id' AND UPPER(`INDEX_TYPE`) = 'BTREE'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 retention index verification failed';
    END IF;

    INSERT INTO `synex_session_control_capacity`
        (`singleton_id`, `entry_count`, `global_limit`, `requester_limit`)
    VALUES (1, 0, 100000, 10000)
    ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);

    SELECT COUNT(*) INTO v_request_count FROM `synex_session_control_requests`;
    IF v_request_count > 4294967295 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 existing request count exceeds counter range';
    END IF;
    IF EXISTS (
        SELECT `requested_by_instance_id`
        FROM `synex_session_control_requests`
        GROUP BY `requested_by_instance_id`
        HAVING COUNT(*) > 4294967295
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 requester count exceeds counter range';
    END IF;

    DELETE FROM `synex_session_control_requester_capacity`;
    INSERT INTO `synex_session_control_requester_capacity`
        (`requested_by_instance_id`, `entry_count`)
    SELECT `requested_by_instance_id`, CAST(COUNT(*) AS UNSIGNED)
    FROM `synex_session_control_requests`
    GROUP BY `requested_by_instance_id`;

    UPDATE `synex_session_control_capacity`
    SET `entry_count` = CAST(v_request_count AS UNSIGNED)
    WHERE `singleton_id` = 1;

    IF (
        SELECT COUNT(*) FROM `synex_session_control_capacity`
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `synex_session_control_capacity`
        WHERE `singleton_id` = 1 AND `entry_count` = v_request_count
            AND `global_limit` > 0 AND `requester_limit` > 0
            AND `requester_limit` <= `global_limit`
    ) OR (
        SELECT COALESCE(SUM(`entry_count`), 0)
        FROM `synex_session_control_requester_capacity`
    ) <> v_request_count OR EXISTS (
        SELECT 1
        FROM (
            SELECT `requested_by_instance_id`, COUNT(*) AS `entry_count`
            FROM `synex_session_control_requests`
            GROUP BY `requested_by_instance_id`
        ) AS `actual`
        LEFT JOIN `synex_session_control_requester_capacity` AS `counter`
            ON `counter`.`requested_by_instance_id` = `actual`.`requested_by_instance_id`
        WHERE `counter`.`requested_by_instance_id` IS NULL
            OR `counter`.`entry_count` <> `actual`.`entry_count`
    ) OR EXISTS (
        SELECT 1 FROM `synex_session_control_requester_capacity` AS `counter`
        LEFT JOIN `synex_session_control_requests` AS `request`
            ON `request`.`requested_by_instance_id` = `counter`.`requested_by_instance_id`
        WHERE `request`.`request_id` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 024 capacity backfill verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_024_session_control_capacity`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_024_session_control_capacity`;
