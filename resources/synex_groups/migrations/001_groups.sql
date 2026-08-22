CREATE TABLE IF NOT EXISTS `synex_groups` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `group_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `created_by_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_groups_public_id` (`public_id`),
    UNIQUE KEY `uq_groups_group_key` (`group_key`),
    KEY `idx_groups_type_status` (`group_type`, `status`, `id`),
    CONSTRAINT `chk_groups_key`
        CHECK (`group_key` REGEXP '^[a-z][a-z0-9_]{2,63}$'),
    CONSTRAINT `chk_groups_type`
        CHECK (`group_type` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_groups_status`
        CHECK (`status` IN ('active', 'suspended', 'archived')),
    CONSTRAINT `chk_groups_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_groups_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_memberships` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `subject_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `role_key` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_memberships_public_id` (`public_id`),
    UNIQUE KEY `uq_group_memberships_subject` (`group_id`, `subject_kind`, `subject_ref`),
    KEY `idx_group_memberships_subject` (`subject_kind`, `subject_ref`, `status`, `group_id`),
    KEY `idx_group_memberships_role` (`group_id`, `role_key`, `status`, `id`),
    CONSTRAINT `fk_group_memberships_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_memberships_subject_kind`
        CHECK (`subject_kind` IN ('user', 'character')),
    CONSTRAINT `chk_group_memberships_role_key`
        CHECK (`role_key` REGEXP '^[a-z][a-z0-9_]{1,47}$'),
    CONSTRAINT `chk_group_memberships_status`
        CHECK (`status` IN ('active', 'suspended', 'removed')),
    CONSTRAINT `chk_group_memberships_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_events` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `membership_version` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_ref` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `snapshot_json` LONGTEXT NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_membership_events_id` (`event_id`),
    UNIQUE KEY `uq_group_membership_events_version` (`membership_id`, `membership_version`),
    KEY `idx_group_membership_events_time` (`occurred_at`, `id`),
    CONSTRAINT `fk_group_membership_events_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_events_version`
        CHECK (`membership_version` > 0),
    CONSTRAINT `chk_group_membership_events_type`
        CHECK (`event_type` IN ('added', 'role_changed', 'suspended', 'removed')),
    CONSTRAINT `chk_group_membership_events_snapshot_json`
        CHECK (JSON_VALID(`snapshot_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_operations` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `idempotency_key` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_fingerprint` LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `response_json` LONGTEXT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_operations_key` (`idempotency_key`),
    KEY `idx_group_operations_state` (`state`, `created_at`, `id`),
    CONSTRAINT `chk_group_operations_state`
        CHECK (`state` IN ('pending', 'completed')),
    CONSTRAINT `chk_group_operations_response_json`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_outbox` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `payload_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `available_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `locked_by` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `published_at` DATETIME(6) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_outbox_event_id` (`event_id`),
    KEY `idx_group_outbox_dispatch` (`state`, `available_at`, `id`),
    KEY `idx_group_outbox_lock` (`locked_until`, `id`),
    KEY `idx_group_outbox_aggregate` (`aggregate_id`, `id`),
    CONSTRAINT `chk_group_outbox_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_group_outbox_payload_json`
        CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_group_outbox_state`
        CHECK (`state` IN ('pending', 'publishing', 'published', 'dead'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
