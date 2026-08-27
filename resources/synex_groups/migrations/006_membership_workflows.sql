CREATE TABLE IF NOT EXISTS `synex_group_primary_memberships_by_type` (
    `character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `assigned_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `assigned_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`character_id`, `group_type_id`),
    UNIQUE KEY `uq_group_primary_by_type_membership` (`membership_id`),
    UNIQUE KEY `uq_group_primary_by_type_public` (`public_id`),
    KEY `idx_group_primary_by_type_type` (`group_type_id`, `character_id`),
    CONSTRAINT `fk_group_primary_by_type_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_primary_by_type_member`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_primary_by_type_character`
        CHECK (`character_id` REGEXP '^[a-z0-9][a-z0-9_:-]{0,47}$'),
    CONSTRAINT `chk_group_primary_by_type_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_primary_by_type_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_primary_by_type_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_primary_memberships_by_type`
    (`character_id`, `group_type_id`, `membership_id`, `public_id`, `assigned_by_ref`,
     `reason_code`, `version`, `assigned_at`)
SELECT `legacy`.`subject_ref`, `profile`.`group_type_id`, `legacy`.`membership_id`,
    CONCAT('gprimary_', SUBSTRING(SHA2(CONCAT(
        'primary:', `legacy`.`subject_ref`, ':', `profile`.`group_type_id`), 256), 1, 32)),
    `legacy`.`assigned_by_ref`, 'legacy_backfill', `legacy`.`version`, `legacy`.`assigned_at`
FROM `synex_group_primary_memberships` AS `legacy`
INNER JOIN `synex_group_memberships` AS `membership`
    ON `membership`.`id` = `legacy`.`membership_id`
INNER JOIN `synex_group_organization_profiles` AS `profile`
    ON `profile`.`group_id` = `membership`.`group_id`
LEFT JOIN `synex_group_primary_memberships_by_type` AS `current_primary`
    ON `current_primary`.`character_id` = `legacy`.`subject_ref`
    AND `current_primary`.`group_type_id` = `profile`.`group_type_id`
WHERE `legacy`.`subject_kind` = 'character'
    AND `current_primary`.`membership_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_profiles` (
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `lifecycle_state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'DRAFT',
    `visibility` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'members',
    `joined_at` DATETIME(6) NULL,
    `suspended_at` DATETIME(6) NULL,
    `left_at` DATETIME(6) NULL,
    `lifecycle_reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`membership_id`),
    UNIQUE KEY `uq_group_membership_profiles_character` (`group_id`, `character_id`),
    KEY `idx_group_membership_profiles_character`
        (`character_id`, `lifecycle_state`, `group_id`, `membership_id`),
    KEY `idx_group_membership_profiles_group`
        (`group_id`, `lifecycle_state`, `visibility`, `membership_id`),
    KEY `idx_group_membership_profiles_departures`
        (`lifecycle_state`, `left_at`, `membership_id`),
    CONSTRAINT `fk_group_membership_profiles_member`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_profiles_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_profiles_character`
        CHECK (`character_id` REGEXP '^[a-z0-9][a-z0-9_:-]{0,47}$'),
    CONSTRAINT `chk_group_membership_profiles_lifecycle`
        CHECK (`lifecycle_state` IN
            ('DRAFT', 'INVITED', 'APPLICANT', 'UNDER_REVIEW', 'APPROVED',
             'PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE',
             'TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')),
    CONSTRAINT `chk_group_membership_profiles_visibility`
        CHECK (`visibility` IN ('public', 'members', 'management', 'private')),
    CONSTRAINT `chk_group_membership_profiles_dates`
        CHECK ((`lifecycle_state` IN
                    ('DRAFT', 'INVITED', 'APPLICANT', 'UNDER_REVIEW', 'APPROVED')
                    AND `joined_at` IS NULL AND `suspended_at` IS NULL AND `left_at` IS NULL)
            OR (`lifecycle_state` IN ('PROBATION', 'ACTIVE')
                    AND `joined_at` IS NOT NULL AND `suspended_at` IS NULL AND `left_at` IS NULL)
            OR (`lifecycle_state` IN ('SUSPENDED', 'LEAVE', 'INACTIVE')
                    AND `joined_at` IS NOT NULL AND `suspended_at` IS NOT NULL AND `left_at` IS NULL)
            OR (`lifecycle_state` IN ('TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED')
                    AND `joined_at` IS NOT NULL AND `left_at` IS NOT NULL
                    AND `left_at` >= `joined_at`)),
    CONSTRAINT `chk_group_membership_profiles_reason`
        CHECK (`lifecycle_reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_membership_profiles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_membership_profiles`
    (`membership_id`, `group_id`, `character_id`, `lifecycle_state`, `visibility`,
     `joined_at`, `suspended_at`, `left_at`, `lifecycle_reason_code`, `version`,
     `created_at`, `updated_at`)
SELECT `membership`.`id`, `membership`.`group_id`, `membership`.`subject_ref`,
    CASE `membership`.`status`
        WHEN 'suspended' THEN 'SUSPENDED'
        WHEN 'removed' THEN 'TERMINATED'
        ELSE 'ACTIVE'
    END,
    'members', `membership`.`created_at`,
    CASE WHEN `membership`.`status` = 'suspended' THEN `membership`.`updated_at` ELSE NULL END,
    CASE WHEN `membership`.`status` = 'removed' THEN `membership`.`updated_at` ELSE NULL END,
    'legacy_backfill', `membership`.`version`, `membership`.`created_at`, `membership`.`updated_at`
FROM `synex_group_memberships` AS `membership`
LEFT JOIN `synex_group_membership_profiles` AS `profile`
    ON `profile`.`membership_id` = `membership`.`id`
WHERE `membership`.`subject_kind` = 'character' AND `profile`.`membership_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_reporting_edges` (
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `manager_membership_id` BIGINT UNSIGNED NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `created_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`membership_id`),
    KEY `idx_group_reporting_manager` (`manager_membership_id`, `membership_id`),
    KEY `idx_group_reporting_group` (`group_id`, `manager_membership_id`, `membership_id`),
    CONSTRAINT `fk_group_reporting_member`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_reporting_manager`
        FOREIGN KEY (`manager_membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_reporting_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_reporting_distinct` CHECK (`membership_id` <> `manager_membership_id`),
    CONSTRAINT `chk_group_reporting_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_reporting_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_reporting_closure` (
    `manager_membership_id` BIGINT UNSIGNED NOT NULL,
    `report_membership_id` BIGINT UNSIGNED NOT NULL,
    `depth` SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (`manager_membership_id`, `report_membership_id`),
    KEY `idx_group_reporting_closure_report`
        (`report_membership_id`, `depth`, `manager_membership_id`),
    CONSTRAINT `fk_group_reporting_closure_manager`
        FOREIGN KEY (`manager_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_reporting_closure_report`
        FOREIGN KEY (`report_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_reporting_closure_depth`
        CHECK ((`manager_membership_id` = `report_membership_id` AND `depth` = 0)
            OR (`manager_membership_id` <> `report_membership_id` AND `depth` > 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_reporting_closure`
    (`manager_membership_id`, `report_membership_id`, `depth`)
SELECT `membership`.`id`, `membership`.`id`, 0
FROM `synex_group_memberships` AS `membership`
LEFT JOIN `synex_group_reporting_closure` AS `closure`
    ON `closure`.`manager_membership_id` = `membership`.`id`
    AND `closure`.`report_membership_id` = `membership`.`id`
WHERE `closure`.`manager_membership_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_invitations` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `grade_id` BIGINT UNSIGNED NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `invited_by_membership_id` BIGINT UNSIGNED NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `expires_at` DATETIME(6) NOT NULL,
    `responded_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `pending_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'pending' THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_invitations_public` (`public_id`),
    UNIQUE KEY `uq_group_invitations_pending`
        (`group_id`, `character_id`, `pending_marker`),
    KEY `idx_group_invitations_character`
        (`character_id`, `status`, `expires_at`, `id`),
    KEY `idx_group_invitations_group` (`group_id`, `status`, `expires_at`, `id`),
    KEY `idx_group_invitations_expiry` (`status`, `expires_at`, `id`),
    CONSTRAINT `fk_group_invitations_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_invitations_grade`
        FOREIGN KEY (`grade_id`) REFERENCES `synex_group_grades` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_invitations_inviter`
        FOREIGN KEY (`invited_by_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_invitations_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_invitations_character`
        CHECK (`character_id` REGEXP '^[a-z0-9][a-z0-9_:-]{0,47}$'),
    CONSTRAINT `chk_group_invitations_status`
        CHECK (`status` IN ('pending', 'accepted', 'declined', 'revoked', 'expired')),
    CONSTRAINT `chk_group_invitations_terminal`
        CHECK ((`status` = 'pending' AND `responded_at` IS NULL)
            OR (`status` <> 'pending' AND `responded_at` IS NOT NULL)),
    CONSTRAINT `chk_group_invitations_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_invitations_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_applications` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `character_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'submitted',
    `application_json` LONGTEXT NOT NULL,
    `reviewed_by_membership_id` BIGINT UNSIGNED NULL,
    `review_reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reviewed_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `open_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` IN ('submitted', 'reviewing') THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_applications_public` (`public_id`),
    UNIQUE KEY `uq_group_applications_open` (`group_id`, `character_id`, `open_marker`),
    KEY `idx_group_applications_group` (`group_id`, `status`, `created_at`, `id`),
    KEY `idx_group_applications_character` (`character_id`, `status`, `created_at`, `id`),
    CONSTRAINT `fk_group_applications_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_applications_reviewer`
        FOREIGN KEY (`reviewed_by_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_applications_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_applications_character`
        CHECK (`character_id` REGEXP '^[a-z0-9][a-z0-9_:-]{0,47}$'),
    CONSTRAINT `chk_group_applications_status`
        CHECK (`status` IN ('submitted', 'reviewing', 'approved', 'rejected', 'withdrawn')),
    CONSTRAINT `chk_group_applications_json` CHECK (JSON_VALID(`application_json`)),
    CONSTRAINT `chk_group_applications_review`
        CHECK ((`status` IN ('submitted', 'reviewing') AND `reviewed_at` IS NULL
                    AND `review_reason_code` IS NULL)
            OR (`status` IN ('approved', 'rejected') AND `reviewed_at` IS NOT NULL
                    AND `reviewed_by_membership_id` IS NOT NULL
                    AND `review_reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$')
            OR (`status` = 'withdrawn' AND `reviewed_at` IS NOT NULL)),
    CONSTRAINT `chk_group_applications_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_duty_states` (
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `display_name` VARCHAR(64) NOT NULL,
    `counts_as_on_duty` TINYINT UNSIGNED NOT NULL,
    `schema_version` INT UNSIGNED NOT NULL DEFAULT 1,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`state_key`),
    KEY `idx_group_duty_states_owner` (`owner_resource`, `status`, `state_key`),
    CONSTRAINT `chk_group_duty_states_key`
        CHECK (`state_key` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_group_duty_states_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_group_duty_states_flag` CHECK (`counts_as_on_duty` IN (0, 1)),
    CONSTRAINT `chk_group_duty_states_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_duty_states_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_duty_states`
    (`state_key`, `public_id`, `owner_resource`, `owner_epoch`, `display_name`,
     `counts_as_on_duty`, `schema_version`, `status`, `version`)
SELECT `seed`.`state_key`,
    CONCAT('group_duty_state_', SUBSTRING(SHA2(
        CONCAT('synex:duty-state:', `seed`.`state_key`), 256), 1, 30)),
    'synex_groups', 1, `seed`.`display_name`, `seed`.`counts_as_on_duty`, 1, 'active', 1
FROM (
    SELECT 'on_duty' AS `state_key`, 'On duty' AS `display_name`, 1 AS `counts_as_on_duty`
    UNION ALL SELECT 'paused', 'Paused', 0
) AS `seed`
LEFT JOIN `synex_group_duty_states` AS `existing`
    ON `existing`.`state_key` = `seed`.`state_key`
WHERE `existing`.`state_key` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_duty_sessions` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'open',
    `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `ended_at` DATETIME(6) NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `open_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'open' THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_duty_sessions_public` (`public_id`),
    UNIQUE KEY `uq_group_duty_sessions_open` (`membership_id`, `open_marker`),
    KEY `idx_group_duty_sessions_state` (`status`, `state_key`, `started_at`, `id`),
    KEY `idx_group_duty_sessions_member` (`membership_id`, `status`, `started_at`, `id`),
    CONSTRAINT `fk_group_duty_sessions_member`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_duty_sessions_state`
        FOREIGN KEY (`state_key`) REFERENCES `synex_group_duty_states` (`state_key`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_duty_sessions_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_duty_sessions_status` CHECK (`status` IN ('open', 'closed')),
    CONSTRAINT `chk_group_duty_sessions_terminal`
        CHECK ((`status` = 'open' AND `ended_at` IS NULL)
            OR (`status` = 'closed' AND `ended_at` IS NOT NULL AND `ended_at` >= `started_at`)),
    CONSTRAINT `chk_group_duty_sessions_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_duty_sessions_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_duty_events` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `duty_session_id` BIGINT UNSIGNED NOT NULL,
    `session_version` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_duty_events_event` (`event_id`),
    UNIQUE KEY `uq_group_duty_events_version` (`duty_session_id`, `session_version`),
    KEY `idx_group_duty_events_time` (`occurred_at`, `id`),
    CONSTRAINT `fk_group_duty_events_session`
        FOREIGN KEY (`duty_session_id`) REFERENCES `synex_group_duty_sessions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_duty_events_state`
        FOREIGN KEY (`state_key`) REFERENCES `synex_group_duty_states` (`state_key`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_duty_events_type`
        CHECK (`event_type` IN ('started', 'state_changed', 'ended')),
    CONSTRAINT `chk_group_duty_events_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_duty_events_version` CHECK (`session_version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_assignments` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `assignment_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `member_limit` SMALLINT UNSIGNED NULL,
    `valid_from` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `valid_until` DATETIME(6) NULL,
    `created_by_membership_id` BIGINT UNSIGNED NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_assignments_public` (`public_id`),
    UNIQUE KEY `uq_group_assignments_group_key` (`group_id`, `assignment_key`),
    KEY `idx_group_assignments_group` (`group_id`, `status`, `valid_until`, `id`),
    KEY `idx_group_assignments_expiry` (`status`, `valid_until`, `id`),
    CONSTRAINT `fk_group_assignments_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_assignments_creator`
        FOREIGN KEY (`created_by_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_assignments_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_assignments_key`
        CHECK (`assignment_key` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_assignments_status`
        CHECK (`status` IN ('active', 'completed', 'cancelled', 'expired')),
    CONSTRAINT `chk_group_assignments_limit`
        CHECK (`member_limit` IS NULL OR `member_limit` > 0),
    CONSTRAINT `chk_group_assignments_window`
        CHECK (`valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `chk_group_assignments_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_assignment_members` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `assignment_id` BIGINT UNSIGNED NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `joined_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `left_at` DATETIME(6) NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'active' THEN 1 ELSE NULL END) STORED,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_assignment_members_active`
        (`assignment_id`, `membership_id`, `active_marker`),
    KEY `idx_group_assignment_members_member`
        (`membership_id`, `status`, `assignment_id`),
    CONSTRAINT `fk_group_assignment_members_assignment`
        FOREIGN KEY (`assignment_id`) REFERENCES `synex_group_assignments` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_assignment_members_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_assignment_members_status`
        CHECK (`status` IN ('active', 'left', 'removed')),
    CONSTRAINT `chk_group_assignment_members_terminal`
        CHECK ((`status` = 'active' AND `left_at` IS NULL)
            OR (`status` <> 'active' AND `left_at` IS NOT NULL)),
    CONSTRAINT `chk_group_assignment_members_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_assignment_members_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_delegations` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `grantor_membership_id` BIGINT UNSIGNED NOT NULL,
    `grantee_membership_id` BIGINT UNSIGNED NOT NULL,
    `capability_pattern` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `valid_from` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `valid_until` DATETIME(6) NOT NULL,
    `revoked_at` DATETIME(6) NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'active' THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_delegations_public` (`public_id`),
    UNIQUE KEY `uq_group_delegations_active`
        (`grantee_membership_id`, `capability_pattern`, `scope_kind`, `scope_ref`, `active_marker`),
    KEY `idx_group_delegations_grantee`
        (`grantee_membership_id`, `status`, `valid_until`, `id`),
    KEY `idx_group_delegations_group`
        (`group_id`, `status`, `valid_until`, `id`),
    KEY `idx_group_delegations_expiry` (`status`, `valid_until`, `id`),
    CONSTRAINT `fk_group_delegations_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_delegations_grantor`
        FOREIGN KEY (`grantor_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_delegations_grantee`
        FOREIGN KEY (`grantee_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_delegations_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_delegations_distinct`
        CHECK (`grantor_membership_id` <> `grantee_membership_id`),
    CONSTRAINT `chk_group_delegations_capability`
        CHECK (`capability_pattern` REGEXP '^[a-z][a-z0-9_.:*?-]{0,127}$'),
    CONSTRAINT `chk_group_delegations_scope`
        CHECK (`scope_kind` IN ('group', 'relationship', 'assignment', 'custom')
            AND ((`scope_kind` = 'group' AND `scope_ref` = '')
                OR (`scope_kind` <> 'group' AND `scope_ref` <> ''))),
    CONSTRAINT `chk_group_delegations_status`
        CHECK (`status` IN ('active', 'revoked', 'expired')),
    CONSTRAINT `chk_group_delegations_window` CHECK (`valid_until` > `valid_from`),
    CONSTRAINT `chk_group_delegations_terminal`
        CHECK ((`status` = 'active' AND `revoked_at` IS NULL)
            OR (`status` <> 'active' AND `revoked_at` IS NOT NULL)),
    CONSTRAINT `chk_group_delegations_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_delegations_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_proposals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `proposal_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `payload_json` LONGTEXT NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `required_approvals` SMALLINT UNSIGNED NOT NULL,
    `expected_group_version` BIGINT UNSIGNED NOT NULL,
    `created_by_membership_id` BIGINT UNSIGNED NOT NULL,
    `expires_at` DATETIME(6) NOT NULL,
    `executed_at` DATETIME(6) NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_proposals_public` (`public_id`),
    KEY `idx_group_proposals_group` (`group_id`, `status`, `expires_at`, `id`),
    KEY `idx_group_proposals_expiry` (`status`, `expires_at`, `id`),
    CONSTRAINT `fk_group_proposals_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_proposals_creator`
        FOREIGN KEY (`created_by_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_proposals_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_proposals_type`
        CHECK (`proposal_type` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_proposals_payload` CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_group_proposals_status`
        CHECK (`status` IN ('pending', 'approved', 'rejected', 'executed', 'cancelled', 'expired')),
    CONSTRAINT `chk_group_proposals_approval_count` CHECK (`required_approvals` > 0),
    CONSTRAINT `chk_group_proposals_terminal`
        CHECK ((`status` = 'executed' AND `executed_at` IS NOT NULL)
            OR (`status` <> 'executed' AND `executed_at` IS NULL)),
    CONSTRAINT `chk_group_proposals_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_proposals_versions`
        CHECK (`version` > 0 AND `expected_group_version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_approvals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `proposal_id` BIGINT UNSIGNED NOT NULL,
    `approver_membership_id` BIGINT UNSIGNED NOT NULL,
    `decision` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `permission_revision` BIGINT UNSIGNED NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `decided_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_approvals_member` (`proposal_id`, `approver_membership_id`),
    KEY `idx_group_approvals_decision` (`proposal_id`, `decision`, `id`),
    CONSTRAINT `fk_group_approvals_proposal`
        FOREIGN KEY (`proposal_id`) REFERENCES `synex_group_proposals` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_approvals_member`
        FOREIGN KEY (`approver_membership_id`)
        REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_approvals_decision`
        CHECK (`decision` IN ('approved', 'rejected', 'revoked')),
    CONSTRAINT `chk_group_approvals_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_approvals_versions`
        CHECK (`version` > 0 AND `permission_revision` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
