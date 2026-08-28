CREATE TABLE IF NOT EXISTS `synex_world_state` (
    `state_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_type` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` INT UNSIGNED NOT NULL,
    `value_type` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `value_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_by_type` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `updated_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_code` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`state_key`, `scope_type`, `scope_ref`),
    KEY `idx_world_state_scope` (`scope_type`, `scope_ref`, `state_key`),
    KEY `idx_world_state_updated` (`updated_at`, `state_key`),
    CONSTRAINT `chk_world_state_scope`
        CHECK (`scope_type` IN ('global', 'region', 'location', 'interior', 'room', 'instance')),
    CONSTRAINT `chk_world_state_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_world_state_value_type`
        CHECK (`value_type` IN ('boolean', 'integer', 'number', 'string', 'enum', 'structured')),
    CONSTRAINT `chk_world_state_value_json`
        CHECK (JSON_VALID(`value_json`)),
    CONSTRAINT `chk_world_state_version`
        CHECK (`version` > 0),
    CONSTRAINT `chk_world_state_actor_type`
        CHECK (`updated_by_type` IN ('resource', 'system', 'user', 'character', 'entity')),
    CONSTRAINT `chk_world_state_source_resource`
        CHECK (`source_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_world_state_reason_code`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_world_door_states` (
    `door_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` INT UNSIGNED NOT NULL DEFAULT 1,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_by_type` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `updated_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_code` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`door_key`),
    KEY `idx_world_door_state` (`state`, `updated_at`, `door_key`),
    CONSTRAINT `chk_world_door_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_world_door_state`
        CHECK (`state` IN ('LOCKED', 'UNLOCKED', 'DISABLED')),
    CONSTRAINT `chk_world_door_version`
        CHECK (`version` > 0),
    CONSTRAINT `chk_world_door_actor_type`
        CHECK (`updated_by_type` IN ('resource', 'system', 'user', 'character', 'entity')),
    CONSTRAINT `chk_world_door_source_resource`
        CHECK (`source_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_world_door_reason_code`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_world_outbox` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `payload_json` LONGTEXT NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `available_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `locked_by` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `published_at` DATETIME(6) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_world_outbox_event_id` (`event_id`),
    KEY `idx_world_outbox_dispatch` (`state`, `available_at`, `id`),
    KEY `idx_world_outbox_lock` (`locked_until`, `id`),
    KEY `idx_world_outbox_aggregate` (`aggregate_id`, `id`),
    CONSTRAINT `chk_world_outbox_event_type`
        CHECK (`event_type` REGEXP '^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$'),
    CONSTRAINT `chk_world_outbox_schema_version`
        CHECK (`schema_version` > 0),
    CONSTRAINT `chk_world_outbox_payload_json`
        CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_world_outbox_state`
        CHECK (`state` IN ('pending', 'publishing', 'published', 'dead'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
