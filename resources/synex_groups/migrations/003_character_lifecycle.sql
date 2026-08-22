CREATE TABLE IF NOT EXISTS `synex_group_character_deletions` (
    `plan_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `anonymous_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `membership_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `primary_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`plan_id`),
    KEY `idx_group_character_deletions_state` (`state`, `created_at`),
    CONSTRAINT `chk_group_character_deletions_plan`
        CHECK (`plan_id` REGEXP '^[A-Za-z0-9_.:-]{8,64}$'),
    CONSTRAINT `chk_group_character_deletions_anonymous_ref`
        CHECK (`anonymous_ref` REGEXP '^[0-9a-f-]{36}$'),
    CONSTRAINT `chk_group_character_deletions_state`
        CHECK ((`state` = 'pending' AND `completed_at` IS NULL)
            OR (`state` = 'completed' AND `completed_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
