CREATE TABLE IF NOT EXISTS `synex_account_reason_codes` (
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(128) NOT NULL,
    `description` VARCHAR(512) NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`reason_code`),
    KEY `idx_account_reason_codes_owner` (`owner_resource`, `status`, `reason_code`),
    CONSTRAINT `chk_account_reason_codes_key`
        CHECK (`reason_code` REGEXP
            '^[a-z][a-z0-9_]*([.][a-z][a-z0-9_]*)+$'),
    CONSTRAINT `chk_account_reason_codes_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_reason_codes_status`
        CHECK (`status` IN ('active', 'deprecated'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_account_reason_codes`
    (`reason_code`, `owner_resource`, `display_name`, `description`, `status`)
VALUES
    ('synex_accounts.legacy.transfer', 'synex_accounts', 'Legacy transfer',
        'Forward-migrated transfer created before reason-code provenance.', 'active'),
    ('synex_accounts.legacy.debit', 'synex_accounts', 'Legacy debit',
        'Forward-migrated debit created before reason-code provenance.', 'active'),
    ('synex_accounts.legacy.credit', 'synex_accounts', 'Legacy credit',
        'Forward-migrated credit created before reason-code provenance.', 'active'),
    ('synex_accounts.legacy.mint', 'synex_accounts', 'Legacy mint',
        'Forward-migrated mint created before reason-code provenance.', 'active'),
    ('synex_accounts.legacy.burn', 'synex_accounts', 'Legacy burn',
        'Forward-migrated burn created before reason-code provenance.', 'active'),
    ('synex_accounts.legacy.hold_capture', 'synex_accounts', 'Legacy hold capture',
        'Forward-migrated hold capture created before reason-code provenance.', 'active'),
    ('synex_accounts.reversal', 'synex_accounts', 'Transaction reversal',
        'A full inverse correction of a posted transaction.', 'active'),
    ('synex_accounts.refund', 'synex_accounts', 'Transaction refund',
        'A full or partial refund of a valid transaction.', 'active'),
    ('synex_accounts.adjustment', 'synex_accounts', 'Account adjustment',
        'A privileged audited ledger adjustment.', 'active'),
    ('synex_accounts.opening_balance', 'synex_accounts', 'Opening balance',
        'A reviewed opening-balance ledger transaction.', 'active'),
    ('synex_accounts.hold', 'synex_accounts', 'Funds hold',
        'Creation or transition of a funds reservation.', 'active');

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD COLUMN IF NOT EXISTS `reason_code`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `transaction_kind`;

-- synex:statement
UPDATE `synex_ledger_transactions`
SET `reason_code` = CASE `transaction_kind`
    WHEN 'transfer' THEN 'synex_accounts.legacy.transfer'
    WHEN 'debit' THEN 'synex_accounts.legacy.debit'
    WHEN 'credit' THEN 'synex_accounts.legacy.credit'
    WHEN 'mint' THEN 'synex_accounts.legacy.mint'
    WHEN 'burn' THEN 'synex_accounts.legacy.burn'
    WHEN 'hold_capture' THEN 'synex_accounts.legacy.hold_capture'
    ELSE 'synex_accounts.legacy.transfer'
END
WHERE `reason_code` IS NULL;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    MODIFY COLUMN `reason_code`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_transactions_reason_time`
    ON `synex_ledger_transactions` (`reason_code`, `occurred_at`, `id`);

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    DROP FOREIGN KEY IF EXISTS `fk_ledger_transactions_reason`;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD CONSTRAINT `fk_ledger_transactions_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT;

-- synex:statement
ALTER TABLE `synex_currencies`
    ADD COLUMN IF NOT EXISTS `precision_locked_at`
        DATETIME(6) NULL AFTER `status`,
    ADD COLUMN IF NOT EXISTS `precision_lock_transaction_id`
        BIGINT UNSIGNED NULL AFTER `precision_locked_at`;

-- synex:statement
UPDATE `synex_currencies` AS `currency`
INNER JOIN (
    SELECT `first_transaction`.`currency_id`, `first_transaction`.`id`,
        `first_transaction`.`occurred_at`
    FROM `synex_ledger_transactions` AS `first_transaction`
    INNER JOIN (
        SELECT `currency_id`, MIN(`id`) AS `first_id`
        FROM `synex_ledger_transactions`
        GROUP BY `currency_id`
    ) AS `first_per_currency`
        ON `first_per_currency`.`first_id` = `first_transaction`.`id`
) AS `history`
    ON `history`.`currency_id` = `currency`.`id`
SET `currency`.`precision_locked_at` = COALESCE(
        `currency`.`precision_locked_at`, `history`.`occurred_at`),
    `currency`.`precision_lock_transaction_id` = COALESCE(
        `currency`.`precision_lock_transaction_id`, `history`.`id`)
WHERE `currency`.`precision_locked_at` IS NULL
    OR `currency`.`precision_lock_transaction_id` IS NULL;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_currencies_precision_lock`
    ON `synex_currencies` (`precision_locked_at`, `id`);

-- synex:statement
ALTER TABLE `synex_currencies`
    DROP FOREIGN KEY IF EXISTS `fk_currencies_precision_lock_transaction`;

-- synex:statement
ALTER TABLE `synex_currencies`
    ADD CONSTRAINT `fk_currencies_precision_lock_transaction`
        FOREIGN KEY (`precision_lock_transaction_id`)
        REFERENCES `synex_ledger_transactions` (`id`) ON DELETE RESTRICT;

-- synex:statement
ALTER TABLE `synex_currencies`
    DROP CONSTRAINT IF EXISTS `chk_currencies_precision_lock`;

-- synex:statement
ALTER TABLE `synex_currencies`
    ADD CONSTRAINT `chk_currencies_precision_lock`
        CHECK ((`precision_locked_at` IS NULL) =
            (`precision_lock_transaction_id` IS NULL));

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_currency_system_topology` (
    `currency_id` BIGINT UNSIGNED NOT NULL,
    `mint_account_id` BIGINT UNSIGNED NULL,
    `burn_account_id` BIGINT UNSIGNED NULL,
    `topology_state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin
        NOT NULL DEFAULT 'incomplete',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`currency_id`),
    UNIQUE KEY `uq_currency_topology_mint` (`mint_account_id`),
    UNIQUE KEY `uq_currency_topology_burn` (`burn_account_id`),
    CONSTRAINT `fk_currency_topology_currency`
        FOREIGN KEY (`currency_id`) REFERENCES `synex_currencies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_currency_topology_mint`
        FOREIGN KEY (`mint_account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_currency_topology_burn`
        FOREIGN KEY (`burn_account_id`) REFERENCES `synex_accounts` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_currency_topology_accounts`
        CHECK (`mint_account_id` IS NULL OR `burn_account_id` IS NULL
            OR `mint_account_id` <> `burn_account_id`),
    CONSTRAINT `chk_currency_topology_state`
        CHECK ((`topology_state` = 'incomplete')
            OR (`topology_state` = 'ready'
                AND `mint_account_id` IS NOT NULL AND `burn_account_id` IS NOT NULL)),
    CONSTRAINT `chk_currency_topology_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_currency_system_topology`
    (`currency_id`, `mint_account_id`, `burn_account_id`, `topology_state`, `version`)
SELECT `currency`.`id`,
    CASE WHEN SUM(`account`.`account_role` = 'mint') = 1
        THEN MAX(CASE WHEN `account`.`account_role` = 'mint' THEN `account`.`id` END)
        ELSE NULL END,
    CASE WHEN SUM(`account`.`account_role` = 'burn') = 1
        THEN MAX(CASE WHEN `account`.`account_role` = 'burn' THEN `account`.`id` END)
        ELSE NULL END,
    CASE WHEN SUM(`account`.`account_role` = 'mint') = 1
            AND SUM(`account`.`account_role` = 'burn') = 1
        THEN 'ready' ELSE 'incomplete' END,
    1
FROM `synex_currencies` AS `currency`
LEFT JOIN `synex_accounts` AS `account`
    ON `account`.`currency_id` = `currency`.`id`
    AND `account`.`account_role` IN ('mint', 'burn')
    AND `account`.`status` <> 'closed'
GROUP BY `currency`.`id`;

-- synex:statement
UPDATE `synex_currency_system_topology` AS `topology`
INNER JOIN (
    SELECT `currency`.`id` AS `currency_id`,
        CASE WHEN SUM(`account`.`account_role` = 'mint') = 1
            THEN MAX(CASE WHEN `account`.`account_role` = 'mint' THEN `account`.`id` END)
            ELSE NULL END AS `mint_account_id`,
        CASE WHEN SUM(`account`.`account_role` = 'burn') = 1
            THEN MAX(CASE WHEN `account`.`account_role` = 'burn' THEN `account`.`id` END)
            ELSE NULL END AS `burn_account_id`
    FROM `synex_currencies` AS `currency`
    LEFT JOIN `synex_accounts` AS `account`
        ON `account`.`currency_id` = `currency`.`id`
        AND `account`.`account_role` IN ('mint', 'burn')
        AND `account`.`status` <> 'closed'
    GROUP BY `currency`.`id`
) AS `candidate`
    ON `candidate`.`currency_id` = `topology`.`currency_id`
SET `topology`.`mint_account_id` = COALESCE(
        `topology`.`mint_account_id`, `candidate`.`mint_account_id`),
    `topology`.`burn_account_id` = COALESCE(
        `topology`.`burn_account_id`, `candidate`.`burn_account_id`),
    `topology`.`topology_state` = CASE
        WHEN COALESCE(`topology`.`mint_account_id`, `candidate`.`mint_account_id`) IS NOT NULL
            AND COALESCE(`topology`.`burn_account_id`, `candidate`.`burn_account_id`) IS NOT NULL
            THEN 'ready'
        ELSE 'incomplete'
    END
WHERE `topology`.`topology_state` = 'incomplete';

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '008_reason_currency_topology',
    (SELECT COUNT(*)
        FROM `synex_ledger_transactions` AS `transaction`
        LEFT JOIN `synex_account_reason_codes` AS `reason`
            ON `reason`.`reason_code` = `transaction`.`reason_code`
        WHERE `transaction`.`reason_code` IS NULL OR `reason`.`reason_code` IS NULL)
    + (SELECT COUNT(*)
        FROM `synex_currencies` AS `currency`
        WHERE EXISTS (SELECT 1 FROM `synex_ledger_transactions` AS `transaction`
                WHERE `transaction`.`currency_id` = `currency`.`id`)
            AND (`currency`.`precision_locked_at` IS NULL
                OR `currency`.`precision_lock_transaction_id` IS NULL))
    + (SELECT COUNT(*)
        FROM `synex_currencies` AS `currency`
        LEFT JOIN `synex_currency_system_topology` AS `topology`
            ON `topology`.`currency_id` = `currency`.`id`
        WHERE `topology`.`currency_id` IS NULL)
    + (SELECT COUNT(*)
        FROM `synex_currency_system_topology` AS `topology`
        LEFT JOIN `synex_accounts` AS `mint`
            ON `mint`.`id` = `topology`.`mint_account_id`
        LEFT JOIN `synex_accounts` AS `burn`
            ON `burn`.`id` = `topology`.`burn_account_id`
        WHERE (`topology`.`mint_account_id` IS NOT NULL
                AND (`mint`.`id` IS NULL OR `mint`.`currency_id` <> `topology`.`currency_id`
                    OR `mint`.`account_role` <> 'mint'))
            OR (`topology`.`burn_account_id` IS NOT NULL
                AND (`burn`.`id` IS NULL OR `burn`.`currency_id` <> `topology`.`currency_id`
                    OR `burn`.`account_role` <> 'burn'))),
    JSON_OBJECT(
        'reasonRegistry', 'synex_account_reason_codes',
        'precisionLock', 'first_financial_transaction',
        'topologyAllowsLegacyIncomplete', TRUE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
