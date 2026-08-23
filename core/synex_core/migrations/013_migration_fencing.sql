CREATE TABLE IF NOT EXISTS `synex_schema_migration_fences` (
    `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `fencing_token` BIGINT UNSIGNED NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `statement_count` SMALLINT UNSIGNED NOT NULL,
    `completed_statements` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `finished_at` DATETIME(6) NULL,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`resource_name`, `migration_id`),
    KEY `idx_schema_migration_fences_state` (`state`, `updated_at`),
    KEY `idx_schema_migration_fences_owner` (`owner_id`, `fencing_token`),
    CONSTRAINT `chk_schema_migration_fences_checksum`
        CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_schema_migration_fences_token`
        CHECK (`fencing_token` > 0),
    CONSTRAINT `chk_schema_migration_fences_state`
        CHECK (`state` IN ('applying', 'applied', 'failed', 'indeterminate')),
    CONSTRAINT `chk_schema_migration_fences_progress`
        CHECK (`completed_statements` <= `statement_count`),
    CONSTRAINT `chk_schema_migration_fences_finished`
        CHECK ((`state` = 'applying' AND `finished_at` IS NULL)
            OR (`state` IN ('applied', 'failed', 'indeterminate') AND `finished_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
