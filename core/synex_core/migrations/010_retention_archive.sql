CREATE TABLE IF NOT EXISTS `synex_audit_archive` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `source_audit_id` BIGINT UNSIGNED NOT NULL,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL,
    `actor_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `action` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `before_json` LONGTEXT NULL,
    `after_json` LONGTEXT NULL,
    `context_json` LONGTEXT NOT NULL,
    `archived_at` DATETIME(6) NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_audit_archive_source` (`source_audit_id`),
    UNIQUE KEY `uq_audit_archive_event_id` (`event_id`),
    KEY `idx_audit_archive_occurred` (`occurred_at`, `source_audit_id`),
    KEY `idx_audit_archive_target` (`target_type`, `target_id`, `source_audit_id`),
    KEY `idx_audit_archive_actor` (`actor_type`, `actor_id`, `source_audit_id`),
    KEY `idx_audit_archive_trace` (`trace_id`, `source_audit_id`),
    CONSTRAINT `chk_audit_archive_source`
        CHECK (`source_audit_id` > 0),
    CONSTRAINT `chk_audit_archive_before_json`
        CHECK (`before_json` IS NULL OR JSON_VALID(`before_json`)),
    CONSTRAINT `chk_audit_archive_after_json`
        CHECK (`after_json` IS NULL OR JSON_VALID(`after_json`)),
    CONSTRAINT `chk_audit_archive_context_json`
        CHECK (JSON_VALID(`context_json`)),
    CONSTRAINT `chk_audit_archive_time`
        CHECK (`archived_at` >= `occurred_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
