CREATE TABLE IF NOT EXISTS `synex_currencies` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `currency_code` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(64) NOT NULL,
    `minor_unit` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_currencies_public_id` (`public_id`),
    UNIQUE KEY `uq_currencies_code` (`currency_code`),
    KEY `idx_currencies_status` (`status`, `id`),
    CONSTRAINT `chk_currencies_code`
        CHECK (`currency_code` REGEXP '^[a-z][a-z0-9_]{1,15}$'),
    CONSTRAINT `chk_currencies_minor_unit`
        CHECK (`minor_unit` BETWEEN 0 AND 6),
    CONSTRAINT `chk_currencies_status`
        CHECK (`status` IN ('active', 'disabled'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_accounts` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `currency_id` BIGINT UNSIGNED NOT NULL,
    `account_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `account_role` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'asset',
    `allow_negative` TINYINT(1) NOT NULL DEFAULT 0,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    `closed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_accounts_public_id` (`public_id`),
    UNIQUE KEY `uq_accounts_currency_key` (`currency_id`, `account_key`),
    KEY `idx_accounts_currency_status` (`currency_id`, `status`, `id`),
    KEY `idx_accounts_role` (`account_role`, `currency_id`, `status`),
    CONSTRAINT `fk_accounts_currency`
        FOREIGN KEY (`currency_id`) REFERENCES `synex_currencies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_accounts_key`
        CHECK (`account_key` IS NULL OR `account_key` REGEXP '^[a-z][a-z0-9_]{2,63}$'),
    CONSTRAINT `chk_accounts_role`
        CHECK (`account_role` IN ('asset', 'mint', 'burn')),
    CONSTRAINT `chk_accounts_negative_role`
        CHECK ((`account_role` = 'mint' AND `allow_negative` = 1) OR (`account_role` <> 'mint' AND `allow_negative` = 0)),
    CONSTRAINT `chk_accounts_status`
        CHECK (`status` IN ('active', 'frozen', 'closed')),
    CONSTRAINT `chk_accounts_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_accounts_version`
        CHECK (`version` > 0),
    CONSTRAINT `chk_accounts_closed_at`
        CHECK ((`status` = 'closed' AND `closed_at` IS NOT NULL) OR (`status` <> 'closed' AND `closed_at` IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_owners` (
    `account_id` BIGINT UNSIGNED NOT NULL,
    `owner_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_ref` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`account_id`),
    KEY `idx_account_owners_subject` (`owner_kind`, `owner_ref`, `account_id`),
    CONSTRAINT `fk_account_owners_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_owners_kind`
        CHECK (`owner_kind` IN ('system', 'user', 'character', 'group')),
    CONSTRAINT `chk_account_owners_ref`
        CHECK (CHAR_LENGTH(`owner_ref`) BETWEEN 1 AND 64)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_operations` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `idempotency_key` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_fingerprint` LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `response_json` LONGTEXT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_operations_key` (`idempotency_key`),
    KEY `idx_account_operations_state` (`state`, `created_at`, `id`),
    CONSTRAINT `chk_account_operations_state`
        CHECK (`state` IN ('pending', 'completed')),
    CONSTRAINT `chk_account_operations_response_json`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
