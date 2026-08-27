CREATE TABLE IF NOT EXISTS `synex_ledger_refund_anchors` (
    `original_transaction_id` BIGINT UNSIGNED NOT NULL,
    `anchor_account_id` BIGINT UNSIGNED NOT NULL,
    `refundable_minor` BIGINT UNSIGNED NOT NULL,
    `refunded_minor` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'open',
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`original_transaction_id`),
    KEY `idx_ledger_refund_anchors_account`
        (`anchor_account_id`, `state`, `updated_at`, `original_transaction_id`),
    CONSTRAINT `fk_ledger_refund_anchors_transaction`
        FOREIGN KEY (`original_transaction_id`)
        REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_refund_anchors_account`
        FOREIGN KEY (`anchor_account_id`) REFERENCES `synex_accounts` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_refund_anchors_entry`
        FOREIGN KEY (`original_transaction_id`, `anchor_account_id`)
        REFERENCES `synex_ledger_entries` (`transaction_id`, `account_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_refund_anchors_amounts`
        CHECK (`refundable_minor` BETWEEN 1 AND 9007199254740991
            AND `refunded_minor` <= `refundable_minor`),
    CONSTRAINT `chk_ledger_refund_anchors_state`
        CHECK ((`state` = 'open' AND `refunded_minor` < `refundable_minor`)
            OR (`state` = 'exhausted' AND `refunded_minor` = `refundable_minor`)),
    CONSTRAINT `chk_ledger_refund_anchors_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_ledger_refund_anchors_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_ledger_refund_anchors_metadata`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_ledger_refund_anchors_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_ledger_refunds` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `anchor_transaction_id` BIGINT UNSIGNED NOT NULL,
    `refund_transaction_id` BIGINT UNSIGNED NOT NULL,
    `sequence_no` INT UNSIGNED NOT NULL,
    `amount_minor` BIGINT UNSIGNED NOT NULL,
    `cumulative_refunded_minor` BIGINT UNSIGNED NOT NULL,
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_ledger_refunds_public_id` (`public_id`),
    UNIQUE KEY `uq_ledger_refunds_transaction` (`refund_transaction_id`),
    UNIQUE KEY `uq_ledger_refunds_anchor_sequence`
        (`anchor_transaction_id`, `sequence_no`),
    KEY `idx_ledger_refunds_anchor` (`anchor_transaction_id`, `created_at`, `id`),
    CONSTRAINT `fk_ledger_refunds_anchor`
        FOREIGN KEY (`anchor_transaction_id`)
        REFERENCES `synex_ledger_refund_anchors` (`original_transaction_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_refunds_transaction`
        FOREIGN KEY (`refund_transaction_id`)
        REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_refunds_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_refunds_sequence`
        CHECK (`sequence_no` > 0),
    CONSTRAINT `chk_ledger_refunds_distinct`
        CHECK (`anchor_transaction_id` <> `refund_transaction_id`),
    CONSTRAINT `chk_ledger_refunds_amounts`
        CHECK (`amount_minor` BETWEEN 1 AND 9007199254740991
            AND `cumulative_refunded_minor` BETWEEN `amount_minor` AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '010_refunds',
    (SELECT COUNT(*)
        FROM `synex_ledger_refund_anchors` AS `anchor`
        LEFT JOIN (
            SELECT `anchor_transaction_id`,
                COALESCE(SUM(`amount_minor`), 0) AS `summed_minor`,
                COALESCE(MAX(`cumulative_refunded_minor`), 0) AS `maximum_cumulative`,
                COUNT(*) AS `refund_count`
            FROM `synex_ledger_refunds`
            GROUP BY `anchor_transaction_id`
        ) AS `refunds`
            ON `refunds`.`anchor_transaction_id` = `anchor`.`original_transaction_id`
        WHERE `anchor`.`refunded_minor` <> COALESCE(`refunds`.`summed_minor`, 0)
            OR `anchor`.`refunded_minor` > `anchor`.`refundable_minor`
            OR COALESCE(`refunds`.`maximum_cumulative`, 0) > `anchor`.`refundable_minor`
            OR (`anchor`.`state` = 'exhausted'
                AND `anchor`.`refunded_minor` <> `anchor`.`refundable_minor`)
            OR (`anchor`.`state` = 'open'
                AND `anchor`.`refunded_minor` >= `anchor`.`refundable_minor`))
    + (SELECT COUNT(*)
        FROM `synex_ledger_refunds` AS `refund`
        INNER JOIN `synex_ledger_refund_anchors` AS `anchor`
            ON `anchor`.`original_transaction_id` = `refund`.`anchor_transaction_id`
        INNER JOIN `synex_ledger_transactions` AS `original`
            ON `original`.`id` = `anchor`.`original_transaction_id`
        INNER JOIN `synex_ledger_transactions` AS `refunded`
            ON `refunded`.`id` = `refund`.`refund_transaction_id`
        INNER JOIN `synex_accounts` AS `anchor_account`
            ON `anchor_account`.`id` = `anchor`.`anchor_account_id`
        WHERE `refund`.`anchor_transaction_id` = `refund`.`refund_transaction_id`
            OR `refunded`.`transaction_kind` <> 'refund'
            OR `original`.`currency_id` <> `refunded`.`currency_id`
            OR `anchor_account`.`currency_id` <> `original`.`currency_id`
            OR `refund`.`cumulative_refunded_minor` <> (
                SELECT SUM(`prior`.`amount_minor`)
                FROM `synex_ledger_refunds` AS `prior`
                WHERE `prior`.`anchor_transaction_id` = `refund`.`anchor_transaction_id`
                    AND `prior`.`sequence_no` <= `refund`.`sequence_no`)),
    JSON_OBJECT(
        'anchor', 'original_transaction_id+anchor_account_id',
        'supportsPartial', TRUE,
        'supportsMultiple', TRUE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
