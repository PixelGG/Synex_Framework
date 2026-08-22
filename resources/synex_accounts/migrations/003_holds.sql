CREATE TABLE IF NOT EXISTS `synex_account_holds` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `capture_account_id` BIGINT UNSIGNED NOT NULL,
    `amount_minor` BIGINT UNSIGNED NOT NULL,
    `reference_text` VARCHAR(128) NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `expires_at` DATETIME(6) NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_holds_public_id` (`public_id`),
    UNIQUE KEY `uq_account_holds_operation` (`operation_id`),
    KEY `idx_account_holds_account_expiry` (`account_id`, `expires_at`, `id`),
    KEY `idx_account_holds_capture_account` (`capture_account_id`, `id`),
    CONSTRAINT `fk_account_holds_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_account_holds_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_account_holds_capture_account`
        FOREIGN KEY (`capture_account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_holds_accounts`
        CHECK (`account_id` <> `capture_account_id`),
    CONSTRAINT `chk_account_holds_amount`
        CHECK (`amount_minor` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `chk_account_holds_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_account_holds_expiry`
        CHECK (`expires_at` > `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_hold_events` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `hold_id` BIGINT UNSIGNED NOT NULL,
    `sequence_no` SMALLINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `terminal_marker` TINYINT UNSIGNED NULL,
    `ledger_transaction_id` BIGINT UNSIGNED NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `snapshot_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_hold_events_id` (`event_id`),
    UNIQUE KEY `uq_account_hold_events_sequence` (`hold_id`, `sequence_no`),
    UNIQUE KEY `uq_account_hold_events_terminal` (`hold_id`, `terminal_marker`),
    KEY `idx_account_hold_events_ledger` (`ledger_transaction_id`),
    CONSTRAINT `fk_account_hold_events_hold`
        FOREIGN KEY (`hold_id`) REFERENCES `synex_account_holds` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_account_hold_events_ledger`
        FOREIGN KEY (`ledger_transaction_id`) REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_account_hold_events_sequence`
        CHECK (`sequence_no` IN (1, 2)),
    CONSTRAINT `chk_account_hold_events_type`
        CHECK (`event_type` IN ('created', 'captured', 'released')),
    CONSTRAINT `chk_account_hold_events_terminal`
        CHECK ((`event_type` = 'created' AND `sequence_no` = 1 AND `terminal_marker` IS NULL AND `ledger_transaction_id` IS NULL)
            OR (`event_type` = 'captured' AND `sequence_no` = 2 AND `terminal_marker` = 1 AND `ledger_transaction_id` IS NOT NULL)
            OR (`event_type` = 'released' AND `sequence_no` = 2 AND `terminal_marker` = 1 AND `ledger_transaction_id` IS NULL)),
    CONSTRAINT `chk_account_hold_events_snapshot_json`
        CHECK (JSON_VALID(`snapshot_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
