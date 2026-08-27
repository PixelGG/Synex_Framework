CREATE TABLE IF NOT EXISTS `synex_ledger_entries` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `transaction_id` BIGINT UNSIGNED NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `sequence_no` SMALLINT UNSIGNED NOT NULL,
    `amount_minor` BIGINT NOT NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_ledger_entries_public_id` (`public_id`),
    UNIQUE KEY `uq_ledger_entries_transaction_sequence` (`transaction_id`, `sequence_no`),
    UNIQUE KEY `uq_ledger_entries_transaction_account` (`transaction_id`, `account_id`),
    KEY `idx_ledger_entries_account` (`account_id`, `created_at`, `id`),
    KEY `idx_ledger_entries_transaction` (`transaction_id`, `id`),
    CONSTRAINT `fk_ledger_entries_transaction`
        FOREIGN KEY (`transaction_id`) REFERENCES `synex_ledger_transactions` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_ledger_entries_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_ledger_entries_sequence`
        CHECK (`sequence_no` BETWEEN 1 AND 64),
    CONSTRAINT `chk_ledger_entries_amount`
        CHECK (`amount_minor` BETWEEN -9007199254740991 AND 9007199254740991
            AND `amount_minor` <> 0),
    CONSTRAINT `chk_ledger_entries_metadata`
        CHECK (JSON_VALID(`metadata_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_ledger_entries`
    (`public_id`, `transaction_id`, `account_id`, `sequence_no`,
        `amount_minor`, `metadata_json`, `created_at`)
SELECT CONCAT(
        SUBSTRING(MD5(CONCAT('synex-entry:debit:', `posting`.`id`)), 1, 8), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:debit:', `posting`.`id`)), 9, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:debit:', `posting`.`id`)), 13, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:debit:', `posting`.`id`)), 17, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:debit:', `posting`.`id`)), 21, 12)),
    `posting`.`transaction_id`, `posting`.`debit_account_id`, 1,
    -CAST(`posting`.`debit_minor` AS SIGNED),
    JSON_OBJECT('legacy_posting_id', `posting`.`public_id`, 'legacy_side', 'debit'),
    `posting`.`created_at`
FROM `synex_ledger_postings` AS `posting`;

-- synex:statement
INSERT IGNORE INTO `synex_ledger_entries`
    (`public_id`, `transaction_id`, `account_id`, `sequence_no`,
        `amount_minor`, `metadata_json`, `created_at`)
SELECT CONCAT(
        SUBSTRING(MD5(CONCAT('synex-entry:credit:', `posting`.`id`)), 1, 8), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:credit:', `posting`.`id`)), 9, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:credit:', `posting`.`id`)), 13, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:credit:', `posting`.`id`)), 17, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-entry:credit:', `posting`.`id`)), 21, 12)),
    `posting`.`transaction_id`, `posting`.`credit_account_id`, 2,
    CAST(`posting`.`credit_minor` AS SIGNED),
    JSON_OBJECT('legacy_posting_id', `posting`.`public_id`, 'legacy_side', 'credit'),
    `posting`.`created_at`
FROM `synex_ledger_postings` AS `posting`;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD COLUMN IF NOT EXISTS `posting_model`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'multi_leg'
        AFTER `currency_id`,
    ADD COLUMN IF NOT EXISTS `entry_count`
        SMALLINT UNSIGNED NOT NULL DEFAULT 2 AFTER `posting_model`,
    ADD COLUMN IF NOT EXISTS `status`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'posted'
        AFTER `metadata_json`,
    ADD COLUMN IF NOT EXISTS `posted_at`
        DATETIME(6) NULL AFTER `occurred_at`;

-- synex:statement
UPDATE `synex_ledger_transactions` AS `transaction`
INNER JOIN (
    SELECT `transaction_id`, COUNT(*) AS `entry_count`
    FROM `synex_ledger_entries`
    GROUP BY `transaction_id`
) AS `entries`
    ON `entries`.`transaction_id` = `transaction`.`id`
SET `transaction`.`posting_model` = CASE
        WHEN EXISTS (SELECT 1 FROM `synex_ledger_postings` AS `legacy`
            WHERE `legacy`.`transaction_id` = `transaction`.`id`)
            THEN 'legacy_pair'
        ELSE `transaction`.`posting_model`
    END,
    `transaction`.`entry_count` = `entries`.`entry_count`,
    `transaction`.`status` = 'posted',
    `transaction`.`posted_at` = COALESCE(
        `transaction`.`posted_at`, `transaction`.`occurred_at`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_transactions_posted`
    ON `synex_ledger_transactions` (`status`, `posted_at`, `id`);

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_kind`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_posting_model`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_entry_count`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_status_v2`;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD CONSTRAINT `chk_ledger_transactions_kind`
        CHECK (`transaction_kind` IN (
            'transfer', 'debit', 'credit', 'mint', 'burn', 'hold_capture',
            'post', 'reversal', 'refund', 'adjustment', 'opening_balance'
        )),
    ADD CONSTRAINT `chk_ledger_transactions_posting_model`
        CHECK (`posting_model` IN ('legacy_pair', 'multi_leg')),
    ADD CONSTRAINT `chk_ledger_transactions_entry_count`
        CHECK ((`posting_model` = 'legacy_pair' AND `entry_count` = 2)
            OR (`posting_model` = 'multi_leg' AND `entry_count` BETWEEN 2 AND 64)),
    ADD CONSTRAINT `chk_ledger_transactions_status_v2`
        CHECK ((`status` = 'pending' AND `posted_at` IS NULL)
            OR (`status` = 'posted' AND `posted_at` IS NOT NULL));

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '009_multileg_ledger',
    (SELECT COUNT(*) FROM (
        SELECT `transaction`.`id`
        FROM `synex_ledger_transactions` AS `transaction`
        LEFT JOIN `synex_ledger_entries` AS `entry`
            ON `entry`.`transaction_id` = `transaction`.`id`
        LEFT JOIN `synex_accounts` AS `account`
            ON `account`.`id` = `entry`.`account_id`
        GROUP BY `transaction`.`id`, `transaction`.`currency_id`, `transaction`.`entry_count`
        HAVING COUNT(`entry`.`id`) <> `transaction`.`entry_count`
            OR COUNT(`entry`.`id`) < 2
            OR COALESCE(SUM(`entry`.`amount_minor`), 1) <> 0
            OR SUM(`account`.`currency_id` <> `transaction`.`currency_id`) <> 0
    ) AS `invalid_transaction`)
    + (SELECT COUNT(*) FROM `synex_ledger_postings` AS `posting`
        WHERE NOT EXISTS (
                SELECT 1 FROM `synex_ledger_entries` AS `entry`
                WHERE `entry`.`transaction_id` = `posting`.`transaction_id`
                    AND `entry`.`account_id` = `posting`.`debit_account_id`
                    AND `entry`.`sequence_no` = 1
                    AND `entry`.`amount_minor` = -CAST(`posting`.`debit_minor` AS SIGNED)
            ) OR NOT EXISTS (
                SELECT 1 FROM `synex_ledger_entries` AS `entry`
                WHERE `entry`.`transaction_id` = `posting`.`transaction_id`
                    AND `entry`.`account_id` = `posting`.`credit_account_id`
                    AND `entry`.`sequence_no` = 2
                    AND `entry`.`amount_minor` = CAST(`posting`.`credit_minor` AS SIGNED)
            )),
    JSON_OBJECT(
        'entryModel', 'signed_minor_units',
        'maximumEntries', 64,
        'legacyTableRetained', TRUE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
