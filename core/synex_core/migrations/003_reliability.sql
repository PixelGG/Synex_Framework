CREATE TABLE IF NOT EXISTS `synex_idempotency_keys` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `namespace` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `idempotency_key` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_hash` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `response_json` LONGTEXT NULL,
    `owner_token` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `locked_until` DATETIME(6) NOT NULL,
    `expires_at` DATETIME(6) NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_idempotency_namespace_key` (`namespace`, `idempotency_key`),
    KEY `idx_idempotency_expiry` (`expires_at`),
    KEY `idx_idempotency_state_lock` (`state`, `locked_until`),
    CONSTRAINT `chk_idempotency_request_hash`
        CHECK (`request_hash` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_idempotency_state`
        CHECK (`state` IN ('pending', 'completed', 'failed')),
    CONSTRAINT `chk_idempotency_response_json`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`)),
    CONSTRAINT `chk_idempotency_expiry`
        CHECK (`expires_at` > `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_outbox` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `payload_json` LONGTEXT NOT NULL,
    `headers_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `available_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `locked_by` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `published_at` DATETIME(6) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_outbox_event_id` (`event_id`),
    KEY `idx_outbox_dispatch` (`state`, `available_at`, `id`),
    KEY `idx_outbox_lock` (`locked_until`, `id`),
    KEY `idx_outbox_aggregate` (`aggregate_type`, `aggregate_id`, `id`),
    CONSTRAINT `chk_outbox_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_outbox_payload_json`
        CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_outbox_headers_json`
        CHECK (JSON_VALID(`headers_json`)),
    CONSTRAINT `chk_outbox_state`
        CHECK (`state` IN ('pending', 'publishing', 'published', 'dead'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_audit_log` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `actor_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `action` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_type` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `before_json` LONGTEXT NULL,
    `after_json` LONGTEXT NULL,
    `context_json` LONGTEXT NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_audit_log_event_id` (`event_id`),
    KEY `idx_audit_log_target` (`target_type`, `target_id`, `id`),
    KEY `idx_audit_log_actor` (`actor_type`, `actor_id`, `id`),
    KEY `idx_audit_log_trace` (`trace_id`, `id`),
    CONSTRAINT `chk_audit_log_before_json`
        CHECK (`before_json` IS NULL OR JSON_VALID(`before_json`)),
    CONSTRAINT `chk_audit_log_after_json`
        CHECK (`after_json` IS NULL OR JSON_VALID(`after_json`)),
    CONSTRAINT `chk_audit_log_context_json`
        CHECK (JSON_VALID(`context_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
