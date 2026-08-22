CREATE TABLE IF NOT EXISTS `synex_financial_transaction_archive` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `source_transaction_id` BIGINT UNSIGNED NOT NULL,
    `transaction_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `posting_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_idempotency_key` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `currency_code` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `currency_minor_unit` TINYINT UNSIGNED NOT NULL,
    `transaction_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reference_text` VARCHAR(128) NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL,
    `debit_account_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `credit_account_public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `debit_minor` BIGINT UNSIGNED NOT NULL,
    `credit_minor` BIGINT UNSIGNED NOT NULL,
    `posting_created_at` DATETIME(6) NOT NULL,
    `archived_at` DATETIME(6) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_financial_archive_source` (`source_transaction_id`),
    UNIQUE KEY `uq_financial_archive_transaction` (`transaction_public_id`),
    UNIQUE KEY `uq_financial_archive_posting` (`posting_public_id`),
    KEY `idx_financial_archive_occurred` (`occurred_at`, `source_transaction_id`),
    KEY `idx_financial_archive_actor` (`actor_ref`, `occurred_at`, `source_transaction_id`),
    KEY `idx_financial_archive_debit` (`debit_account_public_id`, `source_transaction_id`),
    KEY `idx_financial_archive_credit` (`credit_account_public_id`, `source_transaction_id`),
    CONSTRAINT `chk_financial_archive_source`
        CHECK (`source_transaction_id` > 0),
    CONSTRAINT `chk_financial_archive_minor_unit`
        CHECK (`currency_minor_unit` BETWEEN 0 AND 6),
    CONSTRAINT `chk_financial_archive_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_financial_archive_accounts`
        CHECK (`debit_account_public_id` <> `credit_account_public_id`),
    CONSTRAINT `chk_financial_archive_debit_positive`
        CHECK (`debit_minor` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `chk_financial_archive_balanced`
        CHECK (`debit_minor` = `credit_minor`),
    CONSTRAINT `chk_financial_archive_time`
        CHECK (`archived_at` >= `occurred_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
