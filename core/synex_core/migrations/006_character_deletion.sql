CREATE TABLE IF NOT EXISTS `synex_character_deletion_plans` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `character_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `plan_json` LONGTEXT NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `executed_at` DATETIME(6) NULL,
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    KEY `idx_character_deletion_plans_character` (`character_id`, `created_at`, `id`),
    KEY `idx_character_deletion_plans_state` (`state`, `created_at`, `id`),
    CONSTRAINT `fk_character_deletion_plans_character`
        FOREIGN KEY (`character_id`) REFERENCES `synex_characters` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_character_deletion_plans_state`
        CHECK (`state` IN ('pending', 'executing', 'completed', 'failed', 'cancelled')),
    CONSTRAINT `chk_character_deletion_plans_json`
        CHECK (JSON_VALID(`plan_json`)),
    CONSTRAINT `chk_character_deletion_plans_version`
        CHECK (`version` > 0),
    CONSTRAINT `chk_character_deletion_plans_execution`
        CHECK ((`state` IN ('completed', 'failed') AND `executed_at` IS NOT NULL)
            OR (`state` NOT IN ('completed', 'failed') AND `executed_at` IS NULL)),
    CONSTRAINT `chk_character_deletion_plans_failure`
        CHECK ((`state` = 'failed' AND `failure_code` IS NOT NULL)
            OR (`state` <> 'failed' AND `failure_code` IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
