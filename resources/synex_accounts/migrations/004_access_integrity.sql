CREATE TABLE IF NOT EXISTS `synex_account_access_roles` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `role_key` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_access_roles_public_id` (`public_id`),
    UNIQUE KEY `uq_account_access_roles_account_key` (`account_id`, `role_key`),
    UNIQUE KEY `uq_account_access_roles_id_account` (`id`, `account_id`),
    CONSTRAINT `fk_account_access_roles_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_access_roles_key`
        CHECK (`role_key` REGEXP '^[a-z][a-z0-9_]{1,47}$'),
    CONSTRAINT `chk_account_access_roles_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_access_role_permissions` (
    `role_id` BIGINT UNSIGNED NOT NULL,
    `permission_key` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`role_id`, `permission_key`),
    KEY `idx_account_access_permissions_key` (`permission_key`, `role_id`),
    CONSTRAINT `fk_account_access_permissions_role`
        FOREIGN KEY (`role_id`) REFERENCES `synex_account_access_roles` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_access_permissions_key`
        CHECK (`permission_key` IN ('view', 'deposit', 'withdraw', 'transfer', 'history', 'manage', 'close'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_access_grants` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `role_id` BIGINT UNSIGNED NOT NULL,
    `principal_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `principal_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `active_marker` TINYINT UNSIGNED NULL DEFAULT 1,
    `valid_until` DATETIME(6) NULL,
    `granted_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `revoked_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `revocation_reason` VARCHAR(256) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `revoked_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_access_grants_public_id` (`public_id`),
    UNIQUE KEY `uq_account_access_grants_active`
        (`account_id`, `principal_kind`, `principal_ref`, `active_marker`),
    KEY `idx_account_access_grants_role` (`role_id`, `status`, `id`),
    KEY `idx_account_access_grants_expiry` (`status`, `valid_until`, `id`),
    CONSTRAINT `fk_account_access_grants_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_account_access_grants_role_account`
        FOREIGN KEY (`role_id`, `account_id`) REFERENCES `synex_account_access_roles` (`id`, `account_id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_access_grants_principal_kind`
        CHECK (`principal_kind` IN ('system', 'resource', 'user', 'character', 'group')),
    CONSTRAINT `chk_account_access_grants_principal_ref`
        CHECK (CHAR_LENGTH(`principal_ref`) BETWEEN 1 AND 128),
    CONSTRAINT `chk_account_access_grants_status`
        CHECK (`status` IN ('active', 'revoked')),
    CONSTRAINT `chk_account_access_grants_active_marker`
        CHECK ((`status` = 'active' AND `active_marker` IS NOT NULL AND `active_marker` = 1 AND `revoked_at` IS NULL
                AND `revoked_by_ref` IS NULL AND `revocation_reason` IS NULL)
            OR (`status` = 'revoked' AND `active_marker` IS NULL AND `revoked_at` IS NOT NULL
                AND `revoked_by_ref` IS NOT NULL)),
    CONSTRAINT `chk_account_access_grants_validity`
        CHECK (`valid_until` IS NULL OR `valid_until` > `created_at`),
    CONSTRAINT `chk_account_access_grants_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_ledger_reversals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `original_transaction_id` BIGINT UNSIGNED NOT NULL,
    `reversal_transaction_id` BIGINT UNSIGNED NOT NULL,
    `reason` VARCHAR(256) NOT NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_ledger_reversals_public_id` (`public_id`),
    UNIQUE KEY `uq_ledger_reversals_original` (`original_transaction_id`),
    UNIQUE KEY `uq_ledger_reversals_reversal` (`reversal_transaction_id`),
    CONSTRAINT `fk_ledger_reversals_original`
        FOREIGN KEY (`original_transaction_id`) REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_reversals_reversal`
        FOREIGN KEY (`reversal_transaction_id`) REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_reversals_distinct`
        CHECK (`original_transaction_id` <> `reversal_transaction_id`),
    CONSTRAINT `chk_ledger_reversals_reason`
        CHECK (CHAR_LENGTH(`reason`) BETWEEN 1 AND 256)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_economy_integrity_read_models` (
    `currency_id` BIGINT UNSIGNED NOT NULL,
    `model_version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `cutoff_posting_id` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `transaction_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `posting_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `total_debit_minor` DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0,
    `total_credit_minor` DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0,
    `total_booked_minor` DECIMAL(36, 0) NOT NULL DEFAULT 0,
    `negative_asset_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `reserved_exceeds_booked_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `orphan_transaction_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `finding_count` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'healthy',
    `generated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`currency_id`),
    KEY `idx_economy_integrity_status` (`status`, `generated_at`, `currency_id`),
    CONSTRAINT `fk_economy_integrity_currency`
        FOREIGN KEY (`currency_id`) REFERENCES `synex_currencies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_economy_integrity_version`
        CHECK (`model_version` > 0),
    CONSTRAINT `chk_economy_integrity_status`
        CHECK (`status` IN ('healthy', 'warn'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_economy_reconciliation_runs` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `currency_id` BIGINT UNSIGNED NOT NULL,
    `model_version` BIGINT UNSIGNED NOT NULL,
    `cutoff_posting_id` BIGINT UNSIGNED NOT NULL,
    `transaction_count` BIGINT UNSIGNED NOT NULL,
    `posting_count` BIGINT UNSIGNED NOT NULL,
    `total_debit_minor` DECIMAL(36, 0) UNSIGNED NOT NULL,
    `total_credit_minor` DECIMAL(36, 0) UNSIGNED NOT NULL,
    `total_booked_minor` DECIMAL(36, 0) NOT NULL,
    `finding_count` SMALLINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_economy_reconciliation_runs_public_id` (`public_id`),
    UNIQUE KEY `uq_economy_reconciliation_runs_operation` (`operation_id`),
    UNIQUE KEY `uq_economy_reconciliation_currency_version` (`currency_id`, `model_version`),
    KEY `idx_economy_reconciliation_runs_currency` (`currency_id`, `model_version`, `id`),
    CONSTRAINT `fk_economy_reconciliation_runs_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_economy_reconciliation_runs_currency`
        FOREIGN KEY (`currency_id`) REFERENCES `synex_currencies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_economy_reconciliation_runs_version`
        CHECK (`model_version` > 0),
    CONSTRAINT `chk_economy_reconciliation_runs_status`
        CHECK (`status` IN ('healthy', 'warn'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_economy_anomaly_findings` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `run_id` BIGINT UNSIGNED NOT NULL,
    `rule_key` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `severity` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'warn',
    `aggregate_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `aggregate_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `details_json` LONGTEXT NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_economy_anomaly_findings_public_id` (`public_id`),
    UNIQUE KEY `uq_economy_anomaly_findings_rule` (`run_id`, `rule_key`, `aggregate_type`, `aggregate_id`),
    KEY `idx_economy_anomaly_findings_run` (`run_id`, `id`),
    CONSTRAINT `fk_economy_anomaly_findings_run`
        FOREIGN KEY (`run_id`) REFERENCES `synex_economy_reconciliation_runs` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_economy_anomaly_findings_rule`
        CHECK (`rule_key` IN ('ledger_imbalance', 'snapshot_sum_drift', 'negative_asset_balance',
            'reserved_exceeds_booked', 'orphan_transaction')),
    CONSTRAINT `chk_economy_anomaly_findings_severity`
        CHECK (`severity` = 'warn'),
    CONSTRAINT `chk_economy_anomaly_findings_aggregate`
        CHECK ((`aggregate_type` IS NULL) = (`aggregate_id` IS NULL)),
    CONSTRAINT `chk_economy_anomaly_findings_details_json`
        CHECK (JSON_VALID(`details_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_account_access_roles`
    (`public_id`, `account_id`, `role_key`, `display_name`, `version`)
SELECT LOWER(UUID()), `account`.`id`, 'owner', 'Owner', 1
FROM `synex_accounts` AS `account`
LEFT JOIN `synex_account_access_roles` AS `role`
    ON `role`.`account_id` = `account`.`id` AND `role`.`role_key` = 'owner'
WHERE `role`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_account_access_role_permissions` (`role_id`, `permission_key`)
SELECT `role`.`id`, `permission`.`permission_key`
FROM `synex_account_access_roles` AS `role`
CROSS JOIN (SELECT 'view' AS `permission_key` UNION ALL SELECT 'deposit'
    UNION ALL SELECT 'withdraw' UNION ALL SELECT 'transfer' UNION ALL SELECT 'history'
    UNION ALL SELECT 'manage' UNION ALL SELECT 'close') AS `permission`
LEFT JOIN `synex_account_access_role_permissions` AS `existing`
    ON `existing`.`role_id` = `role`.`id` AND `existing`.`permission_key` = `permission`.`permission_key`
WHERE `role`.`role_key` = 'owner' AND `existing`.`role_id` IS NULL;

-- synex:statement
INSERT INTO `synex_account_access_grants`
    (`public_id`, `account_id`, `role_id`, `principal_kind`, `principal_ref`, `status`,
        `active_marker`, `valid_until`, `granted_by_ref`, `version`)
SELECT LOWER(UUID()), `owner`.`account_id`, `role`.`id`, `owner`.`owner_kind`, `owner`.`owner_ref`,
    'active', 1, NULL, NULL, 1
FROM `synex_account_owners` AS `owner`
INNER JOIN `synex_account_access_roles` AS `role`
    ON `role`.`account_id` = `owner`.`account_id` AND `role`.`role_key` = 'owner'
LEFT JOIN `synex_account_access_grants` AS `grant`
    ON `grant`.`account_id` = `owner`.`account_id`
    AND `grant`.`principal_kind` = `owner`.`owner_kind`
    AND `grant`.`principal_ref` = `owner`.`owner_ref`
    AND `grant`.`active_marker` = 1
WHERE `grant`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_economy_integrity_read_models`
    (`currency_id`, `model_version`, `cutoff_posting_id`, `transaction_count`, `posting_count`,
        `total_debit_minor`, `total_credit_minor`, `total_booked_minor`, `negative_asset_count`,
        `reserved_exceeds_booked_count`, `orphan_transaction_count`, `finding_count`, `status`, `generated_at`)
SELECT `currency`.`id`, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 'healthy', CURRENT_TIMESTAMP(6)
FROM `synex_currencies` AS `currency`
LEFT JOIN `synex_economy_integrity_read_models` AS `model` ON `model`.`currency_id` = `currency`.`id`
WHERE `model`.`currency_id` IS NULL;
