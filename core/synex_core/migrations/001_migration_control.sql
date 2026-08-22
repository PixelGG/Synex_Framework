CREATE TABLE IF NOT EXISTS `synex_schema_migrations` (
    `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `applied_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `duration_ms` INT UNSIGNED NOT NULL,
    `instance_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (`resource_name`, `migration_id`),
    CONSTRAINT `chk_schema_migrations_checksum`
        CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_schema_migration_attempts` (
    `resource_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `migration_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `checksum_sha256` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `finished_at` DATETIME(6) NULL,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`resource_name`, `migration_id`),
    KEY `idx_schema_migration_attempts_state` (`state`, `updated_at`),
    CONSTRAINT `chk_schema_migration_attempts_checksum`
        CHECK (`checksum_sha256` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_schema_migration_attempts_state`
        CHECK (`state` IN ('applying', 'applied', 'failed')),
    CONSTRAINT `chk_schema_migration_attempts_count`
        CHECK (`attempts` > 0),
    CONSTRAINT `chk_schema_migration_attempts_finished`
        CHECK ((`state` = 'applying' AND `finished_at` IS NULL)
            OR (`state` IN ('applied', 'failed') AND `finished_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_cluster_leases` (
    `lease_name` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `fencing_token` BIGINT UNSIGNED NOT NULL,
    `expires_at` DATETIME(6) NOT NULL,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`lease_name`),
    KEY `idx_cluster_leases_expiry` (`expires_at`),
    CONSTRAINT `chk_cluster_leases_fencing_token`
        CHECK (`fencing_token` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
