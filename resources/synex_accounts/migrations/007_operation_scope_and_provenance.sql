CREATE TABLE IF NOT EXISTS `synex_account_migration_assertions` (
    `migration_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `violation_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `details_json` LONGTEXT NOT NULL,
    `verified_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`migration_id`),
    CONSTRAINT `chk_account_migration_assertions_zero`
        CHECK (`violation_count` = 0),
    CONSTRAINT `chk_account_migration_assertions_json`
        CHECK (JSON_VALID(`details_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
ALTER TABLE `synex_account_operations`
    MODIFY COLUMN `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    ADD COLUMN IF NOT EXISTS `caller_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'legacy'
        AFTER `idempotency_key`,
    ADD COLUMN IF NOT EXISTS `caller_principal_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `caller_resource`,
    ADD COLUMN IF NOT EXISTS `caller_principal_ref`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `caller_principal_kind`,
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `caller_principal_ref`;

-- synex:statement
CREATE UNIQUE INDEX IF NOT EXISTS `uq_account_operations_scope`
    ON `synex_account_operations`
        (`caller_resource`, `operation_name`, `idempotency_key`);

-- synex:statement
DROP INDEX IF EXISTS `uq_account_operations_key` ON `synex_account_operations`;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_operations_caller_state`
    ON `synex_account_operations`
        (`caller_resource`, `state`, `created_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_operations_trace`
    ON `synex_account_operations` (`trace_id`, `id`);

-- synex:statement
ALTER TABLE `synex_account_operations`
    DROP CONSTRAINT IF EXISTS `chk_account_operations_idempotency_key`,
    DROP CONSTRAINT IF EXISTS `chk_account_operations_caller_resource`,
    DROP CONSTRAINT IF EXISTS `chk_account_operations_caller_principal`,
    DROP CONSTRAINT IF EXISTS `chk_account_operations_trace`;

-- synex:statement
ALTER TABLE `synex_account_operations`
    ADD CONSTRAINT `chk_account_operations_idempotency_key`
        CHECK (CHAR_LENGTH(`idempotency_key`) BETWEEN 8 AND 128
            AND `idempotency_key` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$'),
    ADD CONSTRAINT `chk_account_operations_caller_resource`
        CHECK (`caller_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    ADD CONSTRAINT `chk_account_operations_caller_principal`
        CHECK ((`caller_principal_kind` IS NULL AND `caller_principal_ref` IS NULL)
            OR (`caller_principal_kind` IN
                ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
                AND CHAR_LENGTH(`caller_principal_ref`) BETWEEN 1 AND 128)),
    ADD CONSTRAINT `chk_account_operations_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$'));

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD COLUMN IF NOT EXISTS `source_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'legacy'
        AFTER `transaction_kind`,
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `source_resource`,
    ADD COLUMN IF NOT EXISTS `reference_type`
        VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `trace_id`,
    ADD COLUMN IF NOT EXISTS `reference_id`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `reference_type`,
    ADD COLUMN IF NOT EXISTS `actor_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `actor_ref`;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_transactions_source_time`
    ON `synex_ledger_transactions` (`source_resource`, `occurred_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_transactions_trace`
    ON `synex_ledger_transactions` (`trace_id`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_transactions_reference`
    ON `synex_ledger_transactions` (`reference_type`, `reference_id`, `id`);

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_source_resource`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_trace`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_reference`,
    DROP CONSTRAINT IF EXISTS `chk_ledger_transactions_actor_kind`;

-- synex:statement
ALTER TABLE `synex_ledger_transactions`
    ADD CONSTRAINT `chk_ledger_transactions_source_resource`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    ADD CONSTRAINT `chk_ledger_transactions_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    ADD CONSTRAINT `chk_ledger_transactions_reference`
        CHECK ((`reference_type` IS NULL AND `reference_id` IS NULL)
            OR (`reference_type` REGEXP '^[a-z][a-z0-9_.:-]{1,47}$'
                AND CHAR_LENGTH(`reference_id`) BETWEEN 1 AND 128)),
    ADD CONSTRAINT `chk_ledger_transactions_actor_kind`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL));

-- synex:statement
ALTER TABLE `synex_account_audit`
    ADD COLUMN IF NOT EXISTS `source_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'legacy'
        AFTER `aggregate_id`,
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `source_resource`,
    ADD COLUMN IF NOT EXISTS `reference_type`
        VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `trace_id`,
    ADD COLUMN IF NOT EXISTS `reference_id`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `reference_type`,
    ADD COLUMN IF NOT EXISTS `actor_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `actor_ref`;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_audit_source_time`
    ON `synex_account_audit` (`source_resource`, `occurred_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_audit_trace`
    ON `synex_account_audit` (`trace_id`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_audit_reference`
    ON `synex_account_audit` (`reference_type`, `reference_id`, `id`);

-- synex:statement
ALTER TABLE `synex_account_audit`
    DROP CONSTRAINT IF EXISTS `chk_account_audit_source_resource`,
    DROP CONSTRAINT IF EXISTS `chk_account_audit_trace`,
    DROP CONSTRAINT IF EXISTS `chk_account_audit_reference`,
    DROP CONSTRAINT IF EXISTS `chk_account_audit_actor_kind`;

-- synex:statement
ALTER TABLE `synex_account_audit`
    ADD CONSTRAINT `chk_account_audit_source_resource`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    ADD CONSTRAINT `chk_account_audit_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    ADD CONSTRAINT `chk_account_audit_reference`
        CHECK ((`reference_type` IS NULL AND `reference_id` IS NULL)
            OR (`reference_type` REGEXP '^[a-z][a-z0-9_.:-]{1,47}$'
                AND CHAR_LENGTH(`reference_id`) BETWEEN 1 AND 128)),
    ADD CONSTRAINT `chk_account_audit_actor_kind`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL));

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '007_operation_scope_and_provenance',
    (SELECT 14 - COUNT(*)
        FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND (
            (`TABLE_NAME` = 'synex_account_operations'
                AND `COLUMN_NAME` IN
                    ('caller_resource', 'caller_principal_kind', 'caller_principal_ref', 'trace_id'))
            OR (`TABLE_NAME` = 'synex_ledger_transactions'
                AND `COLUMN_NAME` IN
                    ('source_resource', 'trace_id', 'reference_type', 'reference_id', 'actor_kind'))
            OR (`TABLE_NAME` = 'synex_account_audit'
                AND `COLUMN_NAME` IN
                    ('source_resource', 'trace_id', 'reference_type', 'reference_id', 'actor_kind'))
        ))
    + (SELECT CASE WHEN EXISTS (
            SELECT 1 FROM (
                SELECT `INDEX_NAME`, `NON_UNIQUE`,
                    GROUP_CONCAT(`COLUMN_NAME` ORDER BY `SEQ_IN_INDEX` SEPARATOR ',') AS `columns_csv`
                FROM `information_schema`.`STATISTICS`
                WHERE `TABLE_SCHEMA` = DATABASE()
                    AND `TABLE_NAME` = 'synex_account_operations'
                    AND `INDEX_NAME` = 'uq_account_operations_scope'
                GROUP BY `INDEX_NAME`, `NON_UNIQUE`
            ) AS `scope_index`
            WHERE `scope_index`.`NON_UNIQUE` = 0
                AND `scope_index`.`columns_csv` =
                    'caller_resource,operation_name,idempotency_key'
        ) THEN 0 ELSE 1 END)
    + (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_account_operations'
            AND `INDEX_NAME` = 'uq_account_operations_key')
    + (SELECT COUNT(*) FROM (
        SELECT `caller_resource`, `operation_name`, `idempotency_key`
        FROM `synex_account_operations`
        GROUP BY `caller_resource`, `operation_name`, `idempotency_key`
        HAVING COUNT(*) > 1
    ) AS `duplicate_scope`),
    JSON_OBJECT(
        'scope', 'caller_resource+operation_name+idempotency_key',
        'legacyCaller', 'legacy',
        'historyRewritten', FALSE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
