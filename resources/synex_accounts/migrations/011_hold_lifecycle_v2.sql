ALTER TABLE `synex_account_holds`
    ADD COLUMN IF NOT EXISTS `capture_policy`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'single'
        AFTER `amount_minor`,
    ADD COLUMN IF NOT EXISTS `state`
        VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active'
        AFTER `capture_policy`,
    ADD COLUMN IF NOT EXISTS `captured_minor`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `state`,
    ADD COLUMN IF NOT EXISTS `released_minor`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `captured_minor`,
    ADD COLUMN IF NOT EXISTS `remaining_minor`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `released_minor`,
    ADD COLUMN IF NOT EXISTS `reason_code`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
        DEFAULT 'synex_accounts.hold' AFTER `reference_text`,
    ADD COLUMN IF NOT EXISTS `source_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'legacy'
        AFTER `reason_code`,
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `source_resource`,
    ADD COLUMN IF NOT EXISTS `actor_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `actor_ref`,
    ADD COLUMN IF NOT EXISTS `version`
        BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER `metadata_json`,
    ADD COLUMN IF NOT EXISTS `updated_at`
        DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6) AFTER `created_at`,
    ADD COLUMN IF NOT EXISTS `terminal_at`
        DATETIME(6) NULL AFTER `updated_at`;

-- synex:statement
UPDATE `synex_account_holds` AS `hold`
LEFT JOIN (
    SELECT `event`.`hold_id`,
        MAX(CASE WHEN `event`.`event_type` = 'captured' THEN 1 ELSE 0 END)
            AS `was_captured`,
        MAX(CASE WHEN `event`.`event_type` = 'released' THEN 1 ELSE 0 END)
            AS `was_released`,
        MAX(CASE WHEN `event`.`event_type` IN ('captured', 'released')
            THEN `event`.`occurred_at` END) AS `terminal_at`
    FROM `synex_account_hold_events` AS `event`
    GROUP BY `event`.`hold_id`
) AS `legacy`
    ON `legacy`.`hold_id` = `hold`.`id`
SET `hold`.`capture_policy` = 'single',
    `hold`.`state` = CASE
        WHEN COALESCE(`legacy`.`was_captured`, 0) = 1 THEN 'captured'
        WHEN COALESCE(`legacy`.`was_released`, 0) = 1 THEN 'released'
        WHEN `hold`.`expires_at` <= CURRENT_TIMESTAMP(6) THEN 'expired'
        ELSE 'active'
    END,
    `hold`.`captured_minor` = CASE
        WHEN COALESCE(`legacy`.`was_captured`, 0) = 1 THEN `hold`.`amount_minor`
        ELSE 0
    END,
    `hold`.`released_minor` = CASE
        WHEN COALESCE(`legacy`.`was_released`, 0) = 1
            OR (COALESCE(`legacy`.`was_captured`, 0) = 0
                AND COALESCE(`legacy`.`was_released`, 0) = 0
                AND `hold`.`expires_at` <= CURRENT_TIMESTAMP(6))
            THEN `hold`.`amount_minor`
        ELSE 0
    END,
    `hold`.`remaining_minor` = CASE
        WHEN COALESCE(`legacy`.`was_captured`, 0) = 1
            OR COALESCE(`legacy`.`was_released`, 0) = 1
            OR (COALESCE(`legacy`.`was_captured`, 0) = 0
                AND COALESCE(`legacy`.`was_released`, 0) = 0
                AND `hold`.`expires_at` <= CURRENT_TIMESTAMP(6))
            THEN 0
        ELSE `hold`.`amount_minor`
    END,
    `hold`.`reason_code` = 'synex_accounts.hold',
    `hold`.`source_resource` = 'legacy',
    `hold`.`actor_kind` = CASE
        WHEN `hold`.`actor_ref` IS NULL THEN NULL ELSE 'migration' END,
    `hold`.`version` = GREATEST(`hold`.`version`, 1),
    `hold`.`terminal_at` = CASE
        WHEN COALESCE(`legacy`.`was_captured`, 0) = 1
            OR COALESCE(`legacy`.`was_released`, 0) = 1
            THEN `legacy`.`terminal_at`
        WHEN COALESCE(`legacy`.`was_captured`, 0) = 0
            AND COALESCE(`legacy`.`was_released`, 0) = 0
            AND `hold`.`expires_at` <= CURRENT_TIMESTAMP(6)
            THEN `hold`.`expires_at`
        ELSE NULL
    END;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_holds_state_expiry`
    ON `synex_account_holds` (`state`, `expires_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_holds_account_state`
    ON `synex_account_holds` (`account_id`, `state`, `expires_at`, `id`);

-- synex:statement
ALTER TABLE `synex_account_holds`
    DROP FOREIGN KEY IF EXISTS `fk_account_holds_reason`;

-- synex:statement
ALTER TABLE `synex_account_holds`
    ADD CONSTRAINT `fk_account_holds_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT;

-- synex:statement
ALTER TABLE `synex_account_holds`
    DROP CONSTRAINT IF EXISTS `chk_account_holds_capture_policy`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_state_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_amounts_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_terminal_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_source_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_trace_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_actor_v2`,
    DROP CONSTRAINT IF EXISTS `chk_account_holds_version_v2`;

-- synex:statement
ALTER TABLE `synex_account_holds`
    ADD CONSTRAINT `chk_account_holds_capture_policy`
        CHECK (`capture_policy` IN ('single', 'multiple')
            AND NOT (`capture_policy` = 'single' AND `state` = 'partially_captured')),
    ADD CONSTRAINT `chk_account_holds_state_v2`
        CHECK (`state` IN
            ('active', 'partially_captured', 'captured', 'released', 'expired')),
    ADD CONSTRAINT `chk_account_holds_amounts_v2`
        CHECK (`captured_minor` <= 9007199254740991
            AND `released_minor` <= 9007199254740991
            AND `remaining_minor` <= 9007199254740991
            AND `captured_minor` + `released_minor` + `remaining_minor` = `amount_minor`
            AND ((`state` = 'active' AND `captured_minor` = 0
                    AND `released_minor` = 0 AND `remaining_minor` = `amount_minor`)
                OR (`state` = 'partially_captured' AND `captured_minor` > 0
                    AND `released_minor` = 0 AND `remaining_minor` > 0)
                OR (`state` = 'captured' AND `captured_minor` = `amount_minor`
                    AND `released_minor` = 0 AND `remaining_minor` = 0)
                OR (`state` IN ('released', 'expired')
                    AND `released_minor` > 0 AND `remaining_minor` = 0))),
    ADD CONSTRAINT `chk_account_holds_terminal_v2`
        CHECK ((`state` IN ('active', 'partially_captured') AND `terminal_at` IS NULL)
            OR (`state` IN ('captured', 'released', 'expired')
                AND `terminal_at` IS NOT NULL)),
    ADD CONSTRAINT `chk_account_holds_source_v2`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    ADD CONSTRAINT `chk_account_holds_trace_v2`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    ADD CONSTRAINT `chk_account_holds_actor_v2`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL)),
    ADD CONSTRAINT `chk_account_holds_version_v2`
        CHECK (`version` > 0);

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_hold_events_v2` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `hold_id` BIGINT UNSIGNED NOT NULL,
    `operation_id` BIGINT UNSIGNED NULL,
    `sequence_no` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `amount_minor` BIGINT UNSIGNED NOT NULL,
    `remaining_after_minor` BIGINT UNSIGNED NOT NULL,
    `ledger_transaction_id` BIGINT UNSIGNED NULL,
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `snapshot_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_hold_events_v2_id` (`event_id`),
    UNIQUE KEY `uq_account_hold_events_v2_sequence` (`hold_id`, `sequence_no`),
    KEY `idx_account_hold_events_v2_operation` (`operation_id`, `id`),
    KEY `idx_account_hold_events_v2_ledger` (`ledger_transaction_id`, `id`),
    KEY `idx_account_hold_events_v2_type`
        (`hold_id`, `event_type`, `occurred_at`, `id`),
    CONSTRAINT `fk_account_hold_events_v2_hold`
        FOREIGN KEY (`hold_id`) REFERENCES `synex_account_holds` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_account_hold_events_v2_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_hold_events_v2_ledger`
        FOREIGN KEY (`ledger_transaction_id`) REFERENCES `synex_ledger_transactions` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_hold_events_v2_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_hold_events_v2_sequence`
        CHECK (`sequence_no` > 0),
    CONSTRAINT `chk_account_hold_events_v2_type`
        CHECK (`event_type` IN
            ('created', 'partially_captured', 'captured', 'released', 'expired')),
    CONSTRAINT `chk_account_hold_events_v2_amounts`
        CHECK (`amount_minor` <= 9007199254740991
            AND `remaining_after_minor` <= 9007199254740991
            AND ((`event_type` = 'created' AND `sequence_no` = 1
                    AND `amount_minor` = 0 AND `remaining_after_minor` > 0
                    AND `ledger_transaction_id` IS NULL)
                OR (`event_type` IN ('partially_captured', 'captured')
                    AND `sequence_no` > 1 AND `amount_minor` > 0
                    AND `ledger_transaction_id` IS NOT NULL)
                OR (`event_type` IN ('released', 'expired')
                    AND `sequence_no` > 1 AND `amount_minor` > 0
                    AND `remaining_after_minor` = 0
                    AND `ledger_transaction_id` IS NULL))),
    CONSTRAINT `chk_account_hold_events_v2_terminal`
        CHECK ((`event_type` IN ('captured', 'released', 'expired')
                AND `remaining_after_minor` = 0)
            OR (`event_type` IN ('created', 'partially_captured')
                AND `remaining_after_minor` > 0)),
    CONSTRAINT `chk_account_hold_events_v2_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_hold_events_v2_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_account_hold_events_v2_actor`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_account_hold_events_v2_snapshot`
        CHECK (JSON_VALID(`snapshot_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_account_hold_events_v2`
    (`event_id`, `hold_id`, `operation_id`, `sequence_no`, `event_type`,
        `amount_minor`, `remaining_after_minor`, `ledger_transaction_id`,
        `reason_code`, `source_resource`, `trace_id`, `actor_kind`, `actor_ref`,
        `snapshot_json`, `occurred_at`)
SELECT CONCAT(
        SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 1, 8), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 9, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 13, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 17, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 21, 12)),
    `legacy`.`hold_id`,
    COALESCE(`transaction`.`operation_id`, `hold`.`operation_id`),
    `legacy`.`sequence_no`, `legacy`.`event_type`,
    CASE WHEN `legacy`.`event_type` = 'created' THEN 0 ELSE `hold`.`amount_minor` END,
    CASE WHEN `legacy`.`event_type` = 'created' THEN `hold`.`amount_minor` ELSE 0 END,
    `legacy`.`ledger_transaction_id`, 'synex_accounts.hold', 'legacy', NULL,
    CASE WHEN `legacy`.`actor_ref` IS NULL THEN NULL ELSE 'migration' END,
    `legacy`.`actor_ref`, `legacy`.`snapshot_json`, `legacy`.`occurred_at`
FROM `synex_account_hold_events` AS `legacy`
INNER JOIN `synex_account_holds` AS `hold` ON `hold`.`id` = `legacy`.`hold_id`
LEFT JOIN `synex_ledger_transactions` AS `transaction`
    ON `transaction`.`id` = `legacy`.`ledger_transaction_id`;

-- synex:statement
INSERT IGNORE INTO `synex_account_hold_events_v2`
    (`event_id`, `hold_id`, `operation_id`, `sequence_no`, `event_type`,
        `amount_minor`, `remaining_after_minor`, `ledger_transaction_id`,
        `reason_code`, `source_resource`, `trace_id`, `actor_kind`, `actor_ref`,
        `snapshot_json`, `occurred_at`)
SELECT CONCAT(
        SUBSTRING(MD5(CONCAT('synex-hold-expired-v2:', `hold`.`id`)), 1, 8), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-expired-v2:', `hold`.`id`)), 9, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-expired-v2:', `hold`.`id`)), 13, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-expired-v2:', `hold`.`id`)), 17, 4), '-',
        SUBSTRING(MD5(CONCAT('synex-hold-expired-v2:', `hold`.`id`)), 21, 12)),
    `hold`.`id`, NULL, 2, 'expired', `hold`.`amount_minor`, 0, NULL,
    `hold`.`reason_code`, 'migration', NULL, 'migration', 'migration:011',
    JSON_OBJECT('hold_id', `hold`.`public_id`, 'state', 'expired',
        'released_minor', `hold`.`amount_minor`),
    `hold`.`expires_at`
FROM `synex_account_holds` AS `hold`
WHERE `hold`.`state` = 'expired'
    AND NOT EXISTS (
        SELECT 1 FROM `synex_account_hold_events` AS `legacy`
        WHERE `legacy`.`hold_id` = `hold`.`id`
            AND `legacy`.`event_type` IN ('captured', 'released'));

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '011_hold_expiry_precondition',
    COUNT(*),
    JSON_OBJECT('requirement', 'latest snapshot covers legacy expired reservations')
FROM (
    SELECT `expired`.`account_id`
    FROM (
        SELECT `hold`.`account_id`, SUM(`hold`.`released_minor`) AS `release_minor`
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_account_hold_events_v2` AS `event`
            ON `event`.`hold_id` = `hold`.`id`
            AND `event`.`event_type` = 'expired'
            AND `event`.`source_resource` = 'migration'
        GROUP BY `hold`.`account_id`
    ) AS `expired`
    LEFT JOIN `synex_account_balance_snapshots` AS `latest`
        ON `latest`.`account_id` = `expired`.`account_id`
        AND NOT EXISTS (
            SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
            WHERE `newer`.`account_id` = `latest`.`account_id`
                AND `newer`.`sequence_no` > `latest`.`sequence_no`)
    WHERE `latest`.`id` IS NULL
        OR `latest`.`reserved_minor` < `expired`.`release_minor`
) AS `violation`
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);

-- synex:statement
INSERT INTO `synex_account_balance_snapshots`
    (`account_id`, `sequence_no`, `source_kind`, `source_ref`,
        `booked_minor`, `reserved_minor`, `created_at`)
SELECT `account`.`id`, `latest`.`sequence_no` + 1, 'hold',
    CONCAT(
        SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 1, 8), '-',
        SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 9, 4), '-',
        SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 13, 4), '-',
        SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 17, 4), '-',
        SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 21, 12)),
    `latest`.`booked_minor`, `latest`.`reserved_minor` - `expired`.`release_minor`,
    CURRENT_TIMESTAMP(6)
FROM (
    SELECT `hold`.`account_id`, SUM(`hold`.`released_minor`) AS `release_minor`
    FROM `synex_account_holds` AS `hold`
    INNER JOIN `synex_account_hold_events_v2` AS `event`
        ON `event`.`hold_id` = `hold`.`id`
        AND `event`.`event_type` = 'expired'
        AND `event`.`source_resource` = 'migration'
    GROUP BY `hold`.`account_id`
) AS `expired`
INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `expired`.`account_id`
INNER JOIN `synex_account_balance_snapshots` AS `latest`
    ON `latest`.`account_id` = `account`.`id`
    AND NOT EXISTS (
        SELECT 1 FROM `synex_account_balance_snapshots` AS `newer`
        WHERE `newer`.`account_id` = `latest`.`account_id`
            AND `newer`.`sequence_no` > `latest`.`sequence_no`)
WHERE NOT EXISTS (
    SELECT 1 FROM `synex_account_balance_snapshots` AS `existing`
    WHERE `existing`.`account_id` = `account`.`id`
        AND `existing`.`source_kind` = 'hold'
        AND `existing`.`source_ref` = CONCAT(
            SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 1, 8), '-',
            SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 9, 4), '-',
            SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 13, 4), '-',
            SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 17, 4), '-',
            SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 21, 12)));

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '011_hold_lifecycle_v2',
    (SELECT COUNT(*)
        FROM `synex_account_holds` AS `hold`
        WHERE `hold`.`captured_minor` + `hold`.`released_minor`
                + `hold`.`remaining_minor` <> `hold`.`amount_minor`
            OR (`hold`.`state` IN ('active', 'partially_captured'))
                <> (`hold`.`terminal_at` IS NULL))
    + (SELECT COUNT(*)
        FROM `synex_account_hold_events` AS `legacy`
        WHERE NOT EXISTS (
            SELECT 1 FROM `synex_account_hold_events_v2` AS `event`
            WHERE `event`.`event_id` = CONCAT(
                SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 1, 8), '-',
                SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 9, 4), '-',
                SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 13, 4), '-',
                SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 17, 4), '-',
                SUBSTRING(MD5(CONCAT('synex-hold-event-v2:', `legacy`.`id`)), 21, 12))))
    + (SELECT COUNT(*)
        FROM `synex_account_holds` AS `hold`
        INNER JOIN `synex_account_hold_events_v2` AS `event`
            ON `event`.`hold_id` = `hold`.`id`
            AND `event`.`event_type` = 'expired'
            AND `event`.`source_resource` = 'migration'
        INNER JOIN `synex_accounts` AS `account` ON `account`.`id` = `hold`.`account_id`
        WHERE NOT EXISTS (
            SELECT 1 FROM `synex_account_balance_snapshots` AS `snapshot`
            WHERE `snapshot`.`account_id` = `account`.`id`
                AND `snapshot`.`source_kind` = 'hold'
                AND `snapshot`.`source_ref` = CONCAT(
                    SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 1, 8), '-',
                    SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 9, 4), '-',
                    SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 13, 4), '-',
                    SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 17, 4), '-',
                    SUBSTRING(MD5(CONCAT('migration-011-expiry:', `account`.`public_id`)), 21, 12)))),
    JSON_OBJECT(
        'legacyTableRetained', TRUE,
        'supportsPartialCapture', TRUE,
        'supportsMultipleCapture', TRUE,
        'expiryCorrection', 'append_only_snapshot'
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
