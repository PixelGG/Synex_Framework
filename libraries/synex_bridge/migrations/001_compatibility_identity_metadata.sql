CREATE TABLE IF NOT EXISTS `synex_compatibility_identities` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `provider` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `identifier_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `legacy_identifier` VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    `synex_character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `import_source` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_compat_identity_legacy`
        (`provider`, `identifier_type`, `legacy_identifier`),
    UNIQUE KEY `uq_compat_identity_character`
        (`provider`, `identifier_type`, `synex_character_id`),
    KEY `idx_compat_identity_character` (`synex_character_id`, `provider`),
    CONSTRAINT `chk_compat_identity_provider`
        CHECK (`provider` IN ('qb', 'qbx', 'esx')),
    CONSTRAINT `chk_compat_identity_type`
        CHECK (`identifier_type` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_compat_identity_legacy`
        CHECK (CHAR_LENGTH(`legacy_identifier`) BETWEEN 1 AND 191),
    CONSTRAINT `chk_compat_identity_character`
        CHECK (`synex_character_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]{7,47}$'),
    CONSTRAINT `chk_compat_identity_import_source`
        CHECK (`import_source` IS NULL
            OR `import_source` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]{1,95}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_compatibility_metadata` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `provider` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `synex_character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `metadata_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `value_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_compat_metadata_character`
        (`provider`, `synex_character_id`, `metadata_key`),
    KEY `idx_compat_metadata_character` (`synex_character_id`, `provider`),
    CONSTRAINT `chk_compat_metadata_provider`
        CHECK (`provider` IN ('qb', 'qbx', 'esx')),
    CONSTRAINT `chk_compat_metadata_character`
        CHECK (`synex_character_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]{7,47}$'),
    CONSTRAINT `chk_compat_metadata_key`
        CHECK (`metadata_key` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_compat_metadata_json` CHECK (JSON_VALID(`value_json`)),
    CONSTRAINT `chk_compat_metadata_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
