INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '016_financial_entry_bounds',
    (SELECT COUNT(*) FROM `synex_ledger_transactions`
        WHERE `entry_count` NOT BETWEEN 2 AND 16)
    + (SELECT COUNT(*) FROM `synex_ledger_entries`
        WHERE `sequence_no` NOT BETWEEN 1 AND 16)
    + (SELECT COUNT(*) FROM `synex_financial_transaction_archive_v2`
        WHERE `entry_count` NOT BETWEEN 2 AND 16)
    + (SELECT COUNT(*) FROM `synex_financial_entry_archive_v2`
        WHERE `sequence_no` NOT BETWEEN 1 AND 16),
    JSON_OBJECT(
        'scope', 'live_and_archived_multi_leg_entries',
        'requirement', 'transaction entries are bounded from two through sixteen')
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);

-- synex:statement
ALTER TABLE `synex_ledger_entries`
    DROP CONSTRAINT IF EXISTS `chk_ledger_entries_sequence`;

-- synex:statement
ALTER TABLE `synex_ledger_entries`
    ADD CONSTRAINT `chk_ledger_entries_sequence`
        CHECK (`sequence_no` BETWEEN 1 AND 16);

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_entry_count`;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD CONSTRAINT `chk_ledger_transactions_entry_count`
        CHECK ((`posting_model` = 'legacy_pair' AND `entry_count` = 2)
            OR (`posting_model` = 'multi_leg' AND `entry_count` BETWEEN 2 AND 16));

-- synex:statement
ALTER TABLE `synex_financial_transaction_archive_v2`
    DROP CONSTRAINT IF EXISTS `chk_financial_archive_v2_posting`;

-- synex:statement
ALTER TABLE `synex_financial_transaction_archive_v2`
    ADD CONSTRAINT `chk_financial_archive_v2_posting`
        CHECK (`posting_model` IN ('legacy_pair', 'multi_leg')
            AND `transaction_status` = 'posted'
            AND `entry_count` BETWEEN 2 AND 16
            AND `entry_sum_minor` = 0);

-- synex:statement
ALTER TABLE `synex_financial_entry_archive_v2`
    DROP CONSTRAINT IF EXISTS `chk_financial_entry_archive_v2_sequence`;

-- synex:statement
ALTER TABLE `synex_financial_entry_archive_v2`
    ADD CONSTRAINT `chk_financial_entry_archive_v2_sequence`
        CHECK (`sequence_no` BETWEEN 1 AND 16);
