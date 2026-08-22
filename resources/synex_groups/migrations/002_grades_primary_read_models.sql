CREATE TABLE IF NOT EXISTS `synex_group_grades` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `grade_key` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `rank_value` SMALLINT NOT NULL DEFAULT 0,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_grades_public_id` (`public_id`),
    UNIQUE KEY `uq_group_grades_group_key` (`group_id`, `grade_key`),
    KEY `idx_group_grades_group_rank` (`group_id`, `status`, `rank_value`, `id`),
    CONSTRAINT `fk_group_grades_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_grades_key`
        CHECK (`grade_key` REGEXP '^[a-z][a-z0-9_]{1,47}$'),
    CONSTRAINT `chk_group_grades_status`
        CHECK (`status` IN ('active', 'disabled')),
    CONSTRAINT `chk_group_grades_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_grade_capabilities` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `grade_id` BIGINT UNSIGNED NOT NULL,
    `capability_pattern` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_grade_capability` (`grade_id`, `capability_pattern`),
    KEY `idx_group_grade_capability_pattern` (`capability_pattern`, `effect`, `grade_id`),
    CONSTRAINT `fk_group_grade_capabilities_grade`
        FOREIGN KEY (`grade_id`) REFERENCES `synex_group_grades` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_grade_capability_pattern`
        CHECK (CHAR_LENGTH(`capability_pattern`) BETWEEN 1 AND 128
            AND `capability_pattern` = LOWER(`capability_pattern`)),
    CONSTRAINT `chk_group_grade_capability_effect`
        CHECK (`effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_grade_capability_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_grades` (
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `grade_id` BIGINT UNSIGNED NOT NULL,
    `assigned_by_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `assigned_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`membership_id`),
    KEY `idx_group_membership_grades_grade` (`grade_id`, `membership_id`),
    CONSTRAINT `fk_group_membership_grades_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_grades_grade`
        FOREIGN KEY (`grade_id`) REFERENCES `synex_group_grades` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_grades_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_primary_memberships` (
    `subject_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `assigned_by_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `assigned_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`subject_kind`, `subject_ref`),
    UNIQUE KEY `uq_group_primary_membership` (`membership_id`),
    CONSTRAINT `fk_group_primary_memberships_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_primary_memberships_subject_kind`
        CHECK (`subject_kind` IN ('user', 'character')),
    CONSTRAINT `chk_group_primary_memberships_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_primary_membership_events` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `previous_membership_id` BIGINT UNSIGNED NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `primary_version` BIGINT UNSIGNED NOT NULL,
    `actor_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `snapshot_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_primary_events_id` (`event_id`),
    UNIQUE KEY `uq_group_primary_events_version` (`subject_kind`, `subject_ref`, `primary_version`),
    KEY `idx_group_primary_events_membership` (`membership_id`, `id`),
    CONSTRAINT `fk_group_primary_events_previous`
        FOREIGN KEY (`previous_membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_primary_events_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_primary_events_subject_kind`
        CHECK (`subject_kind` IN ('user', 'character')),
    CONSTRAINT `chk_group_primary_events_version`
        CHECK (`primary_version` > 0),
    CONSTRAINT `chk_group_primary_events_snapshot_json`
        CHECK (JSON_VALID(`snapshot_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_read_model_versions` (
    `group_id` BIGINT UNSIGNED NOT NULL,
    `model_version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `invalidated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_id`),
    KEY `idx_group_read_models_invalidated` (`invalidated_at`, `group_id`),
    CONSTRAINT `fk_group_read_models_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_read_models_version`
        CHECK (`model_version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_grades`
    (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
SELECT LOWER(UUID()), `legacy`.`group_id`, `legacy`.`role_key`, `legacy`.`role_key`, 0, 'active', 1
FROM (SELECT DISTINCT `group_id`, `role_key` FROM `synex_group_memberships`) AS `legacy`
LEFT JOIN `synex_group_grades` AS `grade`
    ON `grade`.`group_id` = `legacy`.`group_id` AND `grade`.`grade_key` = `legacy`.`role_key`
WHERE `grade`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_group_grades`
    (`public_id`, `group_id`, `grade_key`, `display_name`, `rank_value`, `status`, `version`)
SELECT LOWER(UUID()), `group`.`id`, 'member', 'Member', 0, 'active', 1
FROM `synex_groups` AS `group`
WHERE NOT EXISTS (SELECT 1 FROM `synex_group_grades` AS `grade` WHERE `grade`.`group_id` = `group`.`id`);

-- synex:statement
INSERT INTO `synex_group_membership_grades`
    (`membership_id`, `grade_id`, `assigned_by_ref`, `version`)
SELECT `membership`.`id`, `grade`.`id`, NULL, 1
FROM `synex_group_memberships` AS `membership`
INNER JOIN `synex_group_grades` AS `grade`
    ON `grade`.`group_id` = `membership`.`group_id` AND `grade`.`grade_key` = `membership`.`role_key`
LEFT JOIN `synex_group_membership_grades` AS `assigned`
    ON `assigned`.`membership_id` = `membership`.`id`
WHERE `assigned`.`membership_id` IS NULL;

-- synex:statement
INSERT INTO `synex_group_read_model_versions` (`group_id`, `model_version`, `invalidated_at`)
SELECT `group`.`id`, 1, CURRENT_TIMESTAMP(6)
FROM `synex_groups` AS `group`
LEFT JOIN `synex_group_read_model_versions` AS `model` ON `model`.`group_id` = `group`.`id`
WHERE `model`.`group_id` IS NULL;
