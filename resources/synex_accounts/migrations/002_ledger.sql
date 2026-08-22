CREATE TABLE IF NOT EXISTS `synex_ledger_transactions` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `currency_id` BIGINT UNSIGNED NOT NULL,
    `transaction_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reference_text` VARCHAR(128) NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_ledger_transactions_public_id` (`public_id`),
    UNIQUE KEY `uq_ledger_transactions_operation` (`operation_id`),
    KEY `idx_ledger_transactions_currency_time` (`currency_id`, `occurred_at`, `id`),
    KEY `idx_ledger_transactions_actor` (`actor_ref`, `occurred_at`, `id`),
    CONSTRAINT `fk_ledger_transactions_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_transactions_currency`
        FOREIGN KEY (`currency_id`) REFERENCES `synex_currencies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_transactions_kind`
        CHECK (`transaction_kind` IN ('transfer', 'debit', 'credit', 'mint', 'burn', 'hold_capture')),
    CONSTRAINT `chk_ledger_transactions_metadata_json`
        CHECK (JSON_VALID(`metadata_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_ledger_postings` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `transaction_id` BIGINT UNSIGNED NOT NULL,
    `debit_account_id` BIGINT UNSIGNED NOT NULL,
    `credit_account_id` BIGINT UNSIGNED NOT NULL,
    `debit_minor` BIGINT UNSIGNED NOT NULL,
    `credit_minor` BIGINT UNSIGNED NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_ledger_postings_public_id` (`public_id`),
    UNIQUE KEY `uq_ledger_postings_transaction` (`transaction_id`),
    KEY `idx_ledger_postings_debit` (`debit_account_id`, `id`),
    KEY `idx_ledger_postings_credit` (`credit_account_id`, `id`),
    CONSTRAINT `fk_ledger_postings_transaction`
        FOREIGN KEY (`transaction_id`) REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_postings_debit_account`
        FOREIGN KEY (`debit_account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_postings_credit_account`
        FOREIGN KEY (`credit_account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_postings_accounts`
        CHECK (`debit_account_id` <> `credit_account_id`),
    CONSTRAINT `chk_ledger_postings_debit_positive`
        CHECK (`debit_minor` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `chk_ledger_postings_balanced`
        CHECK (`debit_minor` = `credit_minor`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_balance_snapshots` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `sequence_no` BIGINT UNSIGNED NOT NULL,
    `source_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `booked_minor` BIGINT NOT NULL,
    `reserved_minor` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_balance_snapshots_sequence` (`account_id`, `sequence_no`),
    KEY `idx_account_balance_snapshots_source` (`source_kind`, `source_ref`),
    CONSTRAINT `fk_account_balance_snapshots_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_balance_snapshots_source`
        CHECK (`source_kind` IN ('opening', 'ledger', 'hold')),
    CONSTRAINT `chk_account_balance_snapshots_booked`
        CHECK (`booked_minor` BETWEEN -9007199254740991 AND 9007199254740991),
    CONSTRAINT `chk_account_balance_snapshots_reserved`
        CHECK (`reserved_minor` <= 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_audit` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `snapshot_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_audit_event_id` (`event_id`),
    KEY `idx_account_audit_aggregate` (`aggregate_id`, `id`),
    KEY `idx_account_audit_operation` (`operation_id`, `id`),
    CONSTRAINT `fk_account_audit_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_audit_snapshot_json`
        CHECK (JSON_VALID(`snapshot_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_outbox` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `payload_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `available_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `locked_by` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `published_at` DATETIME(6) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_outbox_event_id` (`event_id`),
    KEY `idx_account_outbox_dispatch` (`state`, `available_at`, `id`),
    KEY `idx_account_outbox_lock` (`locked_until`, `id`),
    KEY `idx_account_outbox_aggregate` (`aggregate_id`, `id`),
    CONSTRAINT `chk_account_outbox_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_account_outbox_payload_json`
        CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_account_outbox_state`
        CHECK (`state` IN ('pending', 'publishing', 'published', 'dead'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
