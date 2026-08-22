CREATE TABLE IF NOT EXISTS `synex_legacy_imports` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `framework` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `report_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'running',
    `source_user_count` INT UNSIGNED NOT NULL,
    `source_character_count` INT UNSIGNED NOT NULL,
    `imported_user_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `imported_character_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_legacy_imports_public_id` (`public_id`),
    UNIQUE KEY `uq_legacy_imports_report_digest` (`report_digest`),
    KEY `idx_legacy_imports_state` (`state`, `started_at`, `id`),
    CONSTRAINT `chk_legacy_imports_framework`
        CHECK (`framework` IN ('qb', 'qbx', 'esx')),
    CONSTRAINT `chk_legacy_imports_report_digest`
        CHECK (`report_digest` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_legacy_imports_state`
        CHECK (`state` IN ('running', 'completed')),
    CONSTRAINT `chk_legacy_imports_source_limits`
        CHECK (`source_user_count` <= 10000 AND `source_character_count` <= 10000),
    CONSTRAINT `chk_legacy_imports_progress`
        CHECK (`imported_user_count` <= `source_user_count`
            AND `imported_character_count` <= `source_character_count`),
    CONSTRAINT `chk_legacy_imports_completion`
        CHECK ((`state` = 'running' AND `completed_at` IS NULL)
            OR (`state` = 'completed' AND `completed_at` IS NOT NULL
                AND `imported_user_count` = `source_user_count`
                AND `imported_character_count` = `source_character_count`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_legacy_id_mappings` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `import_id` BIGINT UNSIGNED NOT NULL,
    `framework` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `entity_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `legacy_id_hash` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `synex_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_legacy_id_mappings_source` (`framework`, `entity_kind`, `legacy_id_hash`),
    UNIQUE KEY `uq_legacy_id_mappings_target` (`import_id`, `entity_kind`, `synex_id`),
    KEY `idx_legacy_id_mappings_import` (`import_id`, `id`),
    CONSTRAINT `fk_legacy_id_mappings_import`
        FOREIGN KEY (`import_id`) REFERENCES `synex_legacy_imports` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_legacy_id_mappings_framework`
        CHECK (`framework` IN ('qb', 'qbx', 'esx')),
    CONSTRAINT `chk_legacy_id_mappings_kind`
        CHECK (`entity_kind` IN ('user', 'character')),
    CONSTRAINT `chk_legacy_id_mappings_hash`
        CHECK (`legacy_id_hash` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_legacy_id_mappings_synex_id`
        CHECK (CHAR_LENGTH(`synex_id`) BETWEEN 1 AND 36)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
