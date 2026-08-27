UPDATE `synex_account_operations`
SET `caller_principal_kind` = 'resource',
    `caller_principal_ref` = `caller_resource`
WHERE `caller_principal_kind` IS NULL
    OR `caller_principal_ref` IS NULL;

-- synex:statement
ALTER TABLE `synex_account_operations`
    DROP CONSTRAINT IF EXISTS `chk_account_operations_caller_principal`;

-- synex:statement
ALTER TABLE `synex_account_operations`
    MODIFY COLUMN `caller_principal_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    MODIFY COLUMN `caller_principal_ref`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

-- synex:statement
DROP INDEX IF EXISTS `uq_account_operations_scope` ON `synex_account_operations`;

-- synex:statement
CREATE UNIQUE INDEX IF NOT EXISTS `uq_account_operations_principal_scope`
    ON `synex_account_operations`
        (`caller_resource`, `caller_principal_kind`, `caller_principal_ref`,
            `operation_name`, `idempotency_key`);

-- synex:statement
DROP INDEX IF EXISTS `idx_account_operations_caller_state` ON `synex_account_operations`;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_operations_principal_state`
    ON `synex_account_operations`
        (`caller_resource`, `caller_principal_kind`, `caller_principal_ref`,
            `state`, `created_at`, `id`);

-- synex:statement
ALTER TABLE `synex_account_operations`
    ADD CONSTRAINT `chk_account_operations_caller_principal`
        CHECK (`caller_principal_kind` IN
                ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND CHAR_LENGTH(`caller_principal_ref`) BETWEEN 1 AND 128);

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '017_idempotency_principal_scope',
    (SELECT COUNT(*) FROM `synex_account_operations`
        WHERE `caller_principal_kind` IS NULL OR `caller_principal_ref` IS NULL)
    + (SELECT COUNT(*) FROM (
        SELECT `caller_resource`, `caller_principal_kind`, `caller_principal_ref`,
            `operation_name`, `idempotency_key`
        FROM `synex_account_operations`
        GROUP BY `caller_resource`, `caller_principal_kind`, `caller_principal_ref`,
            `operation_name`, `idempotency_key`
        HAVING COUNT(*) > 1
    ) AS `duplicate_principal_scope`)
    + (SELECT CASE WHEN EXISTS (
        SELECT 1 FROM (
            SELECT `INDEX_NAME`, `NON_UNIQUE`,
                GROUP_CONCAT(`COLUMN_NAME` ORDER BY `SEQ_IN_INDEX` SEPARATOR ',') AS `columns_csv`
            FROM `information_schema`.`STATISTICS`
            WHERE `TABLE_SCHEMA` = DATABASE()
                AND `TABLE_NAME` = 'synex_account_operations'
                AND `INDEX_NAME` = 'uq_account_operations_principal_scope'
            GROUP BY `INDEX_NAME`, `NON_UNIQUE`
        ) AS `principal_scope_index`
        WHERE `principal_scope_index`.`NON_UNIQUE` = 0
            AND `principal_scope_index`.`columns_csv` =
                'caller_resource,caller_principal_kind,caller_principal_ref,operation_name,idempotency_key'
    ) THEN 0 ELSE 1 END)
    + (SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_account_operations'
            AND `INDEX_NAME` = 'uq_account_operations_scope'),
    JSON_OBJECT(
        'scope', 'caller_resource+caller_principal_kind+caller_principal_ref+operation_name+idempotency_key',
        'legacyPrincipal', 'resource:caller_resource',
        'historyEnriched', TRUE
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
