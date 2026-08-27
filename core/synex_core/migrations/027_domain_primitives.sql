CREATE TABLE IF NOT EXISTS `synex_domain_operation_receipts` (
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_hash` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `response_json` LONGTEXT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    `expires_at` DATETIME(6) NOT NULL,
    PRIMARY KEY (`owner_resource`, `operation_name`, `idempotency_key`),
    KEY `idx_domain_receipts_expiry` (`expires_at`, `owner_resource`, `operation_name`, `idempotency_key`),
    CONSTRAINT `chk_domain_receipts_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_receipts_state`
        CHECK (`state` IN ('pending', 'completed')),
    CONSTRAINT `chk_domain_receipts_request_hash`
        CHECK (`request_hash` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_domain_receipts_response`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`)),
    CONSTRAINT `chk_domain_receipts_terminal`
        CHECK ((`state` = 'pending' AND `response_json` IS NULL AND `completed_at` IS NULL)
            OR (`state` = 'completed' AND `response_json` IS NOT NULL AND `completed_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_receipt_capacity` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `global_limit` INT UNSIGNED NOT NULL,
    `owner_limit` INT UNSIGNED NOT NULL,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_domain_receipt_capacity_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_domain_receipt_capacity_limits`
        CHECK (`global_limit` BETWEEN 1 AND 1000000
            AND `owner_limit` BETWEEN 1 AND `global_limit`
            AND `entry_count` <= `global_limit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_domain_receipt_capacity`
    (`singleton_id`, `entry_count`, `global_limit`, `owner_limit`)
VALUES (1, 0, 100000, 10000)
ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_receipt_owner_capacity` (
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`owner_resource`),
    CONSTRAINT `chk_domain_receipt_owner_capacity_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_receipt_owner_capacity_count`
        CHECK (`entry_count` <= 10000)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_plan_capacity` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `global_limit` INT UNSIGNED NOT NULL DEFAULT 10000,
    `owner_limit` INT UNSIGNED NOT NULL DEFAULT 1000,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_domain_deletion_capacity_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_domain_deletion_capacity_limits`
        CHECK (`global_limit` BETWEEN 1 AND 10000
            AND `owner_limit` BETWEEN 1 AND 1000
            AND `owner_limit` <= `global_limit`
            AND `entry_count` <= `global_limit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_domain_deletion_plan_capacity`
    (`singleton_id`, `entry_count`, `global_limit`, `owner_limit`)
VALUES (1, 0, 10000, 1000)
ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_plan_owner_capacity` (
    `requester_owner` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entry_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`requester_owner`),
    CONSTRAINT `chk_domain_deletion_owner_capacity_owner`
        CHECK (`requester_owner` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_deletion_owner_capacity_count`
        CHECK (`entry_count` <= 1000)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_domains` (
    `domain_name` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `provider_count` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`domain_name`),
    CONSTRAINT `chk_domain_deletion_domain_name`
        CHECK (`domain_name` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_domain_deletion_domain_capacity`
        CHECK (`provider_count` BETWEEN 0 AND 64)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_providers` (
    `domain_name` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `provider_owner` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `provider_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` INT UNSIGNED NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `last_bound_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`domain_name`, `provider_owner`, `provider_name`),
    KEY `idx_domain_deletion_provider_owner`
        (`provider_owner`, `domain_name`, `provider_name`),
    CONSTRAINT `chk_domain_deletion_provider_domain`
        CHECK (`domain_name` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_domain_deletion_provider_owner`
        CHECK (`provider_owner` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_deletion_provider_name`
        CHECK (`provider_name` REGEXP '^[a-z][a-z0-9_.-]{1,63}$'),
    CONSTRAINT `chk_domain_deletion_provider_schema`
        CHECK (`schema_version` BETWEEN 1 AND 65535),
    CONSTRAINT `fk_domain_deletion_provider_domain`
        FOREIGN KEY (`domain_name`) REFERENCES `synex_domain_deletion_domains` (`domain_name`)
        ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_plans` (
    `plan_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `domain_name` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requester_owner` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_hash` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_context_json` LONGTEXT NOT NULL,
    `reason` VARCHAR(512) NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `attempt_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `lease_fencing_token` BIGINT UNSIGNED NULL,
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `next_attempt_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    `purge_after` DATETIME(6) NULL,
    PRIMARY KEY (`plan_id`),
    UNIQUE KEY `uq_domain_deletion_request`
        (`requester_owner`, `domain_name`, `idempotency_key`),
    KEY `idx_domain_deletion_due`
        (`state`, `next_attempt_at`, `created_at`, `plan_id`),
    KEY `idx_domain_deletion_subject`
        (`domain_name`, `subject_id`, `created_at`, `plan_id`),
    KEY `idx_domain_deletion_retention` (`purge_after`, `plan_id`),
    CONSTRAINT `chk_domain_deletion_plan_domain`
        CHECK (`domain_name` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_domain_deletion_plan_subject`
        CHECK (`subject_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'),
    CONSTRAINT `chk_domain_deletion_plan_owner`
        CHECK (`requester_owner` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_deletion_plan_hash`
        CHECK (`request_hash` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_domain_deletion_plan_context`
        CHECK (JSON_VALID(`request_context_json`)),
    CONSTRAINT `chk_domain_deletion_plan_state`
        CHECK (`state` IN ('pending', 'executing', 'completed', 'blocked', 'failed')),
    CONSTRAINT `chk_domain_deletion_plan_version` CHECK (`version` > 0),
    CONSTRAINT `chk_domain_deletion_plan_terminal`
        CHECK ((`state` IN ('completed', 'blocked', 'failed')
                AND `completed_at` IS NOT NULL AND `purge_after` IS NOT NULL)
            OR (`state` IN ('pending', 'executing')
                AND `completed_at` IS NULL AND `purge_after` IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_domain_deletion_actions` (
    `plan_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `action_index` SMALLINT UNSIGNED NOT NULL,
    `provider_owner` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `provider_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `provider_schema_version` INT UNSIGNED NOT NULL,
    `decision` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `decision_reason` VARCHAR(512) NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `attempt_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `last_attempt_at` DATETIME(6) NULL,
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`plan_id`, `action_index`),
    UNIQUE KEY `uq_domain_deletion_action_provider`
        (`plan_id`, `provider_owner`, `provider_name`),
    KEY `idx_domain_deletion_action_provider_schema`
        (`provider_owner`, `provider_name`, `state`, `provider_schema_version`,
            `plan_id`, `action_index`),
    CONSTRAINT `fk_domain_deletion_action_plan`
        FOREIGN KEY (`plan_id`) REFERENCES `synex_domain_deletion_plans` (`plan_id`)
        ON DELETE CASCADE,
    CONSTRAINT `chk_domain_deletion_action_index`
        CHECK (`action_index` BETWEEN 1 AND 256),
    CONSTRAINT `chk_domain_deletion_action_owner`
        CHECK (`provider_owner` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_domain_deletion_action_name`
        CHECK (`provider_name` REGEXP '^[a-z][a-z0-9_.-]{1,63}$'),
    CONSTRAINT `chk_domain_deletion_action_schema`
        CHECK (`provider_schema_version` BETWEEN 1 AND 65535),
    CONSTRAINT `chk_domain_deletion_action_decision`
        CHECK (`decision` IN ('allow', 'block', 'delete', 'anonymize', 'retain')),
    CONSTRAINT `chk_domain_deletion_action_metadata`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_domain_deletion_action_state`
        CHECK (`state` IN ('pending', 'completed')),
    CONSTRAINT `chk_domain_deletion_action_version` CHECK (`version` > 0),
    CONSTRAINT `chk_domain_deletion_action_terminal`
        CHECK ((`state` = 'pending' AND `completed_at` IS NULL)
            OR (`state` = 'completed' AND `completed_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_027_domain_deletion_capacity`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_027_domain_deletion_capacity`()
BEGIN
    DECLARE v_plan_count BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_global_limit INT UNSIGNED DEFAULT 0;
    DECLARE v_owner_limit INT UNSIGNED DEFAULT 0;
    DECLARE v_enforced_metadata TINYINT UNSIGNED DEFAULT 0;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `COLUMN_NAME` = 'purge_after'
    ) THEN
        ALTER TABLE `synex_domain_deletion_plans`
            ADD COLUMN `purge_after` DATETIME(6) NULL AFTER `completed_at`;
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'singleton_id'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
            AND UPPER(`INDEX_TYPE`) = 'BTREE'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `INDEX_NAME` = 'PRIMARY' AND `NON_UNIQUE` = 0
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'requester_owner'
            AND `SUB_PART` IS NULL AND `COLLATION` = 'A'
            AND UPPER(`INDEX_TYPE`) = 'BTREE'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion capacity index verification failed';
    END IF;

    UPDATE `synex_domain_deletion_plans`
    SET `purge_after` = TIMESTAMPADD(DAY, 30, `completed_at`)
    WHERE `state` IN ('completed', 'blocked', 'failed')
        AND `completed_at` IS NOT NULL AND `purge_after` IS NULL;

    UPDATE `synex_domain_deletion_plans`
    SET `purge_after` = NULL
    WHERE `state` IN ('pending', 'executing') AND `purge_after` IS NOT NULL;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_plan_terminal'
    ) THEN
        ALTER TABLE `synex_domain_deletion_plans`
            DROP CONSTRAINT `chk_domain_deletion_plan_terminal`;
    END IF;
    ALTER TABLE `synex_domain_deletion_plans`
        ADD CONSTRAINT `chk_domain_deletion_plan_terminal`
        CHECK ((`state` IN ('completed', 'blocked', 'failed')
                AND `completed_at` IS NOT NULL AND `purge_after` IS NOT NULL)
            OR (`state` IN ('pending', 'executing')
                AND `completed_at` IS NULL AND `purge_after` IS NULL));

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `INDEX_NAME` = 'idx_domain_deletion_retention'
    ) THEN
        ALTER TABLE `synex_domain_deletion_plans`
            ADD KEY `idx_domain_deletion_retention` (`purge_after`, `plan_id`);
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_actions'
            AND `INDEX_NAME` = 'idx_domain_deletion_action_provider'
    ) THEN
        ALTER TABLE `synex_domain_deletion_actions`
            DROP INDEX `idx_domain_deletion_action_provider`;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_actions'
            AND `INDEX_NAME` = 'idx_domain_deletion_action_provider_schema'
    ) THEN
        ALTER TABLE `synex_domain_deletion_actions`
            ADD KEY `idx_domain_deletion_action_provider_schema`
                (`provider_owner`, `provider_name`, `state`, `provider_schema_version`,
                    `plan_id`, `action_index`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_domain_deletion_plan_capacity',
                'synex_domain_deletion_plan_owner_capacity'
            )
            AND `TABLE_TYPE` = 'BASE TABLE'
            AND UPPER(`ENGINE`) = 'INNODB'
            AND `TABLE_COLLATION` = 'utf8mb4_unicode_ci'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion capacity table verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
    ) <> 5 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `COLUMN_NAME` = 'singleton_id'
            AND LOWER(`DATA_TYPE`) = 'tinyint'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `COLUMN_NAME` = 'global_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 10000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `COLUMN_NAME` = 'owner_limit'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 1000
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `COLUMN_NAME` = 'updated_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion capacity column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
    ) <> 4 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `COLUMN_NAME` = 'requester_owner'
            AND LOWER(`DATA_TYPE`) = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 64
            AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `COLUMN_NAME` = 'entry_count'
            AND LOWER(`DATA_TYPE`) = 'int'
            AND LOCATE('unsigned', LOWER(`COLUMN_TYPE`)) > 0
            AND LOCATE('zerofill', LOWER(`COLUMN_TYPE`)) = 0
            AND `IS_NULLABLE` = 'NO' AND CAST(`COLUMN_DEFAULT` AS UNSIGNED) = 0
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `COLUMN_NAME` = 'created_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND COALESCE(`EXTRA`, '') = ''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `COLUMN_NAME` = 'updated_at'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'NO'
            AND LOWER(`COLUMN_DEFAULT`) = 'current_timestamp(6)'
            AND TRIM(REPLACE(LOWER(COALESCE(`EXTRA`, '')),
                'default_generated', '')) = 'on update current_timestamp(6)'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `COLUMN_NAME` = 'purge_after'
            AND LOWER(`DATA_TYPE`) = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'YES'
            AND (`COLUMN_DEFAULT` IS NULL
                OR CAST(`COLUMN_DEFAULT` AS BINARY) = CAST('NULL' AS BINARY))
            AND COALESCE(`EXTRA`, '') = ''
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion retention column verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `INDEX_NAME` = 'idx_domain_deletion_retention'
    ) <> 2 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `INDEX_NAME` = 'idx_domain_deletion_retention'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'purge_after' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A' AND UPPER(`INDEX_TYPE`) = 'BTREE'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plans'
            AND `INDEX_NAME` = 'idx_domain_deletion_retention'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'plan_id' AND `SUB_PART` IS NULL
            AND `COLLATION` = 'A' AND UPPER(`INDEX_TYPE`) = 'BTREE'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion retention index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_actions'
            AND `INDEX_NAME` = 'idx_domain_deletion_action_provider_schema'
    ) <> 6 OR EXISTS (
        SELECT 1
        FROM (
            SELECT 1 AS `sequence`, 'provider_owner' AS `column_name`
            UNION ALL SELECT 2, 'provider_name'
            UNION ALL SELECT 3, 'state'
            UNION ALL SELECT 4, 'provider_schema_version'
            UNION ALL SELECT 5, 'plan_id'
            UNION ALL SELECT 6, 'action_index'
        ) AS `expected`
        LEFT JOIN `information_schema`.`STATISTICS` AS `actual`
            ON `actual`.`TABLE_SCHEMA` = DATABASE()
            AND `actual`.`TABLE_NAME` = 'synex_domain_deletion_actions'
            AND `actual`.`INDEX_NAME` = 'idx_domain_deletion_action_provider_schema'
            AND `actual`.`SEQ_IN_INDEX` = `expected`.`sequence`
            AND `actual`.`COLUMN_NAME` = `expected`.`column_name`
            AND `actual`.`NON_UNIQUE` = 1 AND `actual`.`SUB_PART` IS NULL
            AND `actual`.`COLLATION` = 'A' AND UPPER(`actual`.`INDEX_TYPE`) = 'BTREE'
        WHERE `actual`.`INDEX_NAME` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion provider schema index verification failed';
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
    ) <> 3 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_capacity_singleton'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_capacity'
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_capacity_limits'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_owner_capacity_owner'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_domain_deletion_plan_owner_capacity'
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_owner_capacity_count'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_capacity_singleton'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'singleton_id=1'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_capacity_limits'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '')
                = 'global_limitbetween1and10000andowner_limitbetween1and1000andowner_limit<=global_limitandentry_count<=global_limit'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_owner_capacity_owner'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                    CHAR(9), ''), CHAR(10), ''), CHAR(13), ''),
                '_utf8mb4', ''), '_utf8mb3', ''), '_utf8', ''),
                '_ascii', ''), '_latin1', '')
                = 'requester_ownerregexp''^synex_[a-z0-9_]+$'''
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_owner_capacity_count'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '') = 'entry_count<=1000'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`CHECK_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` = 'chk_domain_deletion_plan_terminal'
            AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                LOWER(`CHECK_CLAUSE`), '`', ''), ' ', ''), '(', ''), ')', ''),
                CHAR(9), ''), CHAR(10), ''), CHAR(13), '')
                LIKE '%purge_afterisnotnull%purge_afterisnull%'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion constraint verification failed';
    END IF;

    SELECT COUNT(*) INTO v_enforced_metadata
    FROM `information_schema`.`COLUMNS`
    WHERE LOWER(`TABLE_SCHEMA`) = 'information_schema'
        AND UPPER(`TABLE_NAME`) = 'TABLE_CONSTRAINTS'
        AND UPPER(`COLUMN_NAME`) = 'ENFORCED';
    IF v_enforced_metadata > 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 check enforcement metadata is ambiguous';
    END IF;
    IF v_enforced_metadata = 1 THEN
        SET @synex_migrate_027_enforced_checks = NULL;
        SET @synex_migrate_027_enforced_sql =
            'SELECT COUNT(*) INTO @synex_migrate_027_enforced_checks '
            'FROM information_schema.TABLE_CONSTRAINTS '
            'WHERE CONSTRAINT_SCHEMA = DATABASE() AND CONSTRAINT_TYPE = ''CHECK'' '
            'AND ((TABLE_NAME = ''synex_domain_deletion_plan_capacity'' '
            'AND CONSTRAINT_NAME IN (''chk_domain_deletion_capacity_singleton'', '
            '''chk_domain_deletion_capacity_limits'')) '
            'OR (TABLE_NAME = ''synex_domain_deletion_plan_owner_capacity'' '
            'AND CONSTRAINT_NAME IN (''chk_domain_deletion_owner_capacity_owner'', '
            '''chk_domain_deletion_owner_capacity_count'')) '
            'OR (TABLE_NAME = ''synex_domain_deletion_plans'' '
            'AND CONSTRAINT_NAME = ''chk_domain_deletion_plan_terminal'')) '
            'AND UPPER(COALESCE(ENFORCED, ''NO'')) = ''YES''';
        PREPARE synex_migrate_027_enforced_statement
            FROM @synex_migrate_027_enforced_sql;
        EXECUTE synex_migrate_027_enforced_statement;
        DEALLOCATE PREPARE synex_migrate_027_enforced_statement;
        IF COALESCE(@synex_migrate_027_enforced_checks, 0) <> 5 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'synex migration 027 deletion checks are not enforced';
        END IF;
        SET @synex_migrate_027_enforced_checks = NULL;
        SET @synex_migrate_027_enforced_sql = NULL;
    END IF;

    SELECT `global_limit`, `owner_limit`
    INTO v_global_limit, v_owner_limit
    FROM `synex_domain_deletion_plan_capacity`
    WHERE `singleton_id` = 1;
    IF v_global_limit < 1 OR v_global_limit > 10000
        OR v_owner_limit < 1 OR v_owner_limit > 1000
        OR v_owner_limit > v_global_limit THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion capacity limits are invalid';
    END IF;

    SELECT COUNT(*) INTO v_plan_count FROM `synex_domain_deletion_plans`;
    IF v_plan_count > v_global_limit OR EXISTS (
        SELECT `requester_owner` FROM `synex_domain_deletion_plans`
        GROUP BY `requester_owner` HAVING COUNT(*) > v_owner_limit
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion plan capacity is exceeded';
    END IF;

    DELETE FROM `synex_domain_deletion_plan_owner_capacity`;
    INSERT INTO `synex_domain_deletion_plan_owner_capacity`
        (`requester_owner`, `entry_count`)
    SELECT `requester_owner`, CAST(COUNT(*) AS UNSIGNED)
    FROM `synex_domain_deletion_plans`
    GROUP BY `requester_owner`;
    UPDATE `synex_domain_deletion_plan_capacity`
    SET `entry_count` = CAST(v_plan_count AS UNSIGNED)
    WHERE `singleton_id` = 1;

    IF (
        SELECT COUNT(*) FROM `synex_domain_deletion_plan_capacity`
    ) <> 1 OR NOT EXISTS (
        SELECT 1 FROM `synex_domain_deletion_plan_capacity`
        WHERE `singleton_id` = 1 AND `entry_count` = v_plan_count
            AND `global_limit` = v_global_limit AND `owner_limit` = v_owner_limit
    ) OR (
        SELECT COALESCE(SUM(`entry_count`), 0)
        FROM `synex_domain_deletion_plan_owner_capacity`
    ) <> v_plan_count OR EXISTS (
        SELECT 1 FROM (
            SELECT `requester_owner`, COUNT(*) AS `entry_count`
            FROM `synex_domain_deletion_plans` GROUP BY `requester_owner`
        ) AS `actual`
        LEFT JOIN `synex_domain_deletion_plan_owner_capacity` AS `counter`
            ON `counter`.`requester_owner` = `actual`.`requester_owner`
        WHERE `counter`.`requester_owner` IS NULL
            OR `counter`.`entry_count` <> `actual`.`entry_count`
    ) OR EXISTS (
        SELECT 1 FROM `synex_domain_deletion_plan_owner_capacity` AS `counter`
        LEFT JOIN `synex_domain_deletion_plans` AS `plan`
            ON `plan`.`requester_owner` = `counter`.`requester_owner`
        WHERE `plan`.`plan_id` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 027 deletion capacity backfill verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_027_domain_deletion_capacity`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_027_domain_deletion_capacity`;
