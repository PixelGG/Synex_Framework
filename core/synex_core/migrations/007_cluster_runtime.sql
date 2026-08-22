CREATE TABLE IF NOT EXISTS `synex_instances` (
    `instance_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `name` VARCHAR(96) NOT NULL,
    `started_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `heartbeat_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (`instance_id`),
    KEY `idx_instances_health` (`status`, `heartbeat_at`),
    CONSTRAINT `chk_instances_status`
        CHECK (`status` IN ('starting', 'ready', 'degraded', 'stopping', 'stopped', 'stale')),
    CONSTRAINT `chk_instances_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_session_control_requests` (
    `request_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_session_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_by_instance_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `action` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `reason` VARCHAR(128) NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `expires_at` DATETIME(6) NOT NULL,
    `completed_at` DATETIME(6) NULL,
    `active_marker` TINYINT GENERATED ALWAYS AS (
        CASE WHEN `state` = 'pending' THEN 1 ELSE NULL END
    ) STORED,
    PRIMARY KEY (`request_id`),
    UNIQUE KEY `uq_session_control_active` (`target_session_id`, `action`, `active_marker`),
    KEY `idx_session_control_dispatch` (`state`, `expires_at`, `target_session_id`),
    CONSTRAINT `fk_session_control_session`
        FOREIGN KEY (`target_session_id`) REFERENCES `synex_sessions` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_session_control_instance`
        FOREIGN KEY (`requested_by_instance_id`) REFERENCES `synex_instances` (`instance_id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_session_control_action` CHECK (`action` IN ('kick')),
    CONSTRAINT `chk_session_control_state` CHECK (`state` IN ('pending', 'completed', 'expired')),
    CONSTRAINT `chk_session_control_expiry` CHECK (`expires_at` > `created_at`),
    CONSTRAINT `chk_session_control_completion`
        CHECK ((`state` = 'pending' AND `completed_at` IS NULL)
            OR (`state` IN ('completed', 'expired') AND `completed_at` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
