ALTER TABLE `synex_financial_transaction_archive`
    MODIFY COLUMN `operation_idempotency_key`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_financial_transaction_archive_v2` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `source_transaction_id` BIGINT UNSIGNED NOT NULL,
    `transaction_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_idempotency_key`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `caller_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `caller_principal_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `caller_principal_ref`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `currency_code` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `currency_minor_unit` TINYINT UNSIGNED NOT NULL,
    `transaction_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `posting_model` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `transaction_status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reference_type` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reference_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reference_text` VARCHAR(128) NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `entry_count` SMALLINT UNSIGNED NOT NULL,
    `entry_sum_minor` DECIMAL(36, 0) NOT NULL,
    `source_schema_version` SMALLINT UNSIGNED NOT NULL DEFAULT 2,
    `occurred_at` DATETIME(6) NOT NULL,
    `posted_at` DATETIME(6) NOT NULL,
    `archived_at` DATETIME(6) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_financial_archive_v2_source` (`source_transaction_id`),
    UNIQUE KEY `uq_financial_archive_v2_public` (`transaction_public_id`),
    KEY `idx_financial_archive_v2_occurred`
        (`occurred_at`, `source_transaction_id`),
    KEY `idx_financial_archive_v2_reason`
        (`reason_code`, `occurred_at`, `source_transaction_id`),
    KEY `idx_financial_archive_v2_resource`
        (`source_resource`, `occurred_at`, `source_transaction_id`),
    KEY `idx_financial_archive_v2_reference`
        (`reference_type`, `reference_id`, `source_transaction_id`),
    KEY `idx_financial_archive_v2_trace` (`trace_id`, `source_transaction_id`),
    CONSTRAINT `chk_financial_archive_v2_source`
        CHECK (`source_transaction_id` > 0),
    CONSTRAINT `chk_financial_archive_v2_minor_unit`
        CHECK (`currency_minor_unit` BETWEEN 0 AND 6),
    CONSTRAINT `chk_financial_archive_v2_posting`
        CHECK (`posting_model` IN ('legacy_pair', 'multi_leg')
            AND `transaction_status` = 'posted'
            AND `entry_count` BETWEEN 2 AND 64
            AND `entry_sum_minor` = 0),
    CONSTRAINT `chk_financial_archive_v2_caller`
        CHECK ((`caller_principal_kind` IS NULL AND `caller_principal_ref` IS NULL)
            OR (`caller_principal_kind` IN
                ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
                AND `caller_principal_ref` IS NOT NULL)),
    CONSTRAINT `chk_financial_archive_v2_reference`
        CHECK ((`reference_type` IS NULL AND `reference_id` IS NULL)
            OR (`reference_type` IS NOT NULL AND `reference_id` IS NOT NULL)),
    CONSTRAINT `chk_financial_archive_v2_actor`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_financial_archive_v2_resource`
        CHECK (`caller_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'
            AND `source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_financial_archive_v2_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_financial_archive_v2_metadata`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_financial_archive_v2_schema`
        CHECK (`source_schema_version` >= 2),
    CONSTRAINT `chk_financial_archive_v2_time`
        CHECK (`posted_at` >= `occurred_at` AND `archived_at` >= `posted_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_financial_entry_archive_v2` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `archive_transaction_id` BIGINT UNSIGNED NOT NULL,
    `source_entry_id` BIGINT UNSIGNED NOT NULL,
    `entry_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `sequence_no` SMALLINT UNSIGNED NOT NULL,
    `account_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `account_role` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `amount_minor` BIGINT NOT NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `entry_created_at` DATETIME(6) NOT NULL,
    `archived_at` DATETIME(6) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_financial_entry_archive_v2_source` (`source_entry_id`),
    UNIQUE KEY `uq_financial_entry_archive_v2_public` (`entry_public_id`),
    UNIQUE KEY `uq_financial_entry_archive_v2_sequence`
        (`archive_transaction_id`, `sequence_no`),
    KEY `idx_financial_entry_archive_v2_account`
        (`account_public_id`, `archive_transaction_id`, `sequence_no`),
    CONSTRAINT `fk_financial_entry_archive_v2_transaction`
        FOREIGN KEY (`archive_transaction_id`)
        REFERENCES `synex_financial_transaction_archive_v2` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_financial_entry_archive_v2_sequence`
        CHECK (`sequence_no` BETWEEN 1 AND 64),
    CONSTRAINT `chk_financial_entry_archive_v2_role`
        CHECK (`account_role` IN ('asset', 'mint', 'burn')),
    CONSTRAINT `chk_financial_entry_archive_v2_amount`
        CHECK (`amount_minor` <> 0
            AND `amount_minor` BETWEEN -9007199254740991 AND 9007199254740991),
    CONSTRAINT `chk_financial_entry_archive_v2_metadata`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_financial_entry_archive_v2_time`
        CHECK (`archived_at` >= `entry_created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '015_financial_archive_precondition',
    COUNT(*),
    JSON_OBJECT(
        'scope', 'legacy_archive_only',
        'requirement', 'canonical live entries remain complete and balanced')
FROM (
    SELECT `legacy`.`source_transaction_id`
    FROM `synex_financial_transaction_archive` AS `legacy`
    LEFT JOIN `synex_ledger_transactions` AS `transaction`
        ON `transaction`.`id` = `legacy`.`source_transaction_id`
    LEFT JOIN `synex_account_operations` AS `operation`
        ON `operation`.`id` = `transaction`.`operation_id`
    LEFT JOIN `synex_ledger_entries` AS `entry`
        ON `entry`.`transaction_id` = `transaction`.`id`
    GROUP BY `legacy`.`source_transaction_id`, `transaction`.`id`, `operation`.`id`,
        `transaction`.`entry_count`
    HAVING `transaction`.`id` IS NULL OR `operation`.`id` IS NULL
        OR COUNT(`entry`.`id`) <> `transaction`.`entry_count`
        OR COUNT(`entry`.`id`) < 2
        OR COALESCE(SUM(`entry`.`amount_minor`), 1) <> 0
) AS `violation`
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);

-- synex:statement
INSERT INTO `synex_financial_transaction_archive_v2`
    (`source_transaction_id`, `transaction_public_id`, `operation_idempotency_key`,
        `operation_name`, `caller_resource`, `caller_principal_kind`,
        `caller_principal_ref`, `currency_code`, `currency_minor_unit`,
        `transaction_kind`, `posting_model`, `transaction_status`, `reason_code`,
        `reference_type`, `reference_id`, `reference_text`, `actor_kind`, `actor_ref`,
        `source_resource`, `trace_id`, `metadata_json`, `entry_count`,
        `entry_sum_minor`, `source_schema_version`, `occurred_at`, `posted_at`,
        `archived_at`)
SELECT `legacy`.`source_transaction_id`, `legacy`.`transaction_public_id`,
    `operation`.`idempotency_key`, `operation`.`operation_name`,
    `operation`.`caller_resource`, `operation`.`caller_principal_kind`,
    `operation`.`caller_principal_ref`, `legacy`.`currency_code`,
    `legacy`.`currency_minor_unit`, `transaction`.`transaction_kind`,
    `transaction`.`posting_model`, `transaction`.`status`, `transaction`.`reason_code`,
    `transaction`.`reference_type`, `transaction`.`reference_id`,
    `transaction`.`reference_text`, `transaction`.`actor_kind`,
    `transaction`.`actor_ref`, `transaction`.`source_resource`,
    COALESCE(`transaction`.`trace_id`, `operation`.`trace_id`),
    `transaction`.`metadata_json`, `transaction`.`entry_count`,
    `entry_sum`.`entry_sum_minor`, 2, `transaction`.`occurred_at`,
    `transaction`.`posted_at`, `legacy`.`archived_at`
FROM `synex_financial_transaction_archive` AS `legacy`
INNER JOIN `synex_ledger_transactions` AS `transaction`
    ON `transaction`.`id` = `legacy`.`source_transaction_id`
INNER JOIN `synex_account_operations` AS `operation`
    ON `operation`.`id` = `transaction`.`operation_id`
INNER JOIN (
    SELECT `transaction_id`, SUM(`amount_minor`) AS `entry_sum_minor`
    FROM `synex_ledger_entries`
    GROUP BY `transaction_id`
) AS `entry_sum` ON `entry_sum`.`transaction_id` = `transaction`.`id`
LEFT JOIN `synex_financial_transaction_archive_v2` AS `existing`
    ON `existing`.`source_transaction_id` = `legacy`.`source_transaction_id`
WHERE `existing`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_financial_entry_archive_v2`
    (`archive_transaction_id`, `source_entry_id`, `entry_public_id`, `sequence_no`,
        `account_public_id`, `account_role`, `amount_minor`, `metadata_json`,
        `entry_created_at`, `archived_at`)
SELECT `archive`.`id`, `entry`.`id`, `entry`.`public_id`, `entry`.`sequence_no`,
    `account`.`public_id`, `account`.`account_role`, `entry`.`amount_minor`,
    `entry`.`metadata_json`, `entry`.`created_at`, `archive`.`archived_at`
FROM `synex_financial_transaction_archive_v2` AS `archive`
INNER JOIN `synex_financial_transaction_archive` AS `legacy`
    ON `legacy`.`source_transaction_id` = `archive`.`source_transaction_id`
INNER JOIN `synex_ledger_entries` AS `entry`
    ON `entry`.`transaction_id` = `legacy`.`source_transaction_id`
INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `entry`.`account_id`
LEFT JOIN `synex_financial_entry_archive_v2` AS `existing`
    ON `existing`.`source_entry_id` = `entry`.`id`
WHERE `existing`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '015_financial_archive_v2',
    (SELECT COUNT(*)
        FROM `synex_financial_transaction_archive` AS `legacy`
        WHERE NOT EXISTS (
            SELECT 1 FROM `synex_financial_transaction_archive_v2` AS `archive`
            WHERE `archive`.`source_transaction_id` = `legacy`.`source_transaction_id`))
    + (SELECT COUNT(*) FROM (
        SELECT `archive`.`id`, `archive`.`entry_count`
        FROM `synex_financial_transaction_archive_v2` AS `archive`
        INNER JOIN `synex_financial_transaction_archive` AS `legacy`
            ON `legacy`.`source_transaction_id` = `archive`.`source_transaction_id`
        LEFT JOIN `synex_financial_entry_archive_v2` AS `entry`
            ON `entry`.`archive_transaction_id` = `archive`.`id`
        GROUP BY `archive`.`id`, `archive`.`entry_count`
        HAVING COUNT(`entry`.`id`) <> `archive`.`entry_count`
            OR COALESCE(SUM(`entry`.`amount_minor`), 1) <> 0
    ) AS `invalid_archive`),
    JSON_OBJECT(
        'legacyArchiveRetained', TRUE,
        'multiLegArchive', TRUE,
        'liveTableForeignKeys', FALSE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
