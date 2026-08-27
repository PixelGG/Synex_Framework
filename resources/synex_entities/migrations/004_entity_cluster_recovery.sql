CREATE TABLE IF NOT EXISTS `synex_entity_authority_leases` (
    `entity_id` VARCHAR(64) NOT NULL,
    `server_scope` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `instance_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `authority_token` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `resource_epoch` BIGINT UNSIGNED NOT NULL,
    `lease_generation` BIGINT UNSIGNED NOT NULL,
    `lease_state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `claimed_at` DATETIME(6) NOT NULL,
    `heartbeat_at` DATETIME(6) NOT NULL,
    `lease_until` DATETIME(6) NOT NULL,
    `released_at` DATETIME(6) NULL,
    `last_trace_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`entity_id`),
    KEY `idx_synex_entity_authority_expiry`
        (`lease_state`, `lease_until`, `entity_id`),
    KEY `idx_synex_entity_authority_instance`
        (`instance_id`, `lease_state`, `entity_id`),
    KEY `idx_synex_entity_authority_token`
        (`authority_token`, `resource_epoch`, `lease_state`, `entity_id`),
    KEY `idx_synex_entity_authority_scope`
        (`server_scope`, `lease_state`, `lease_until`, `entity_id`),
    CONSTRAINT `fk_synex_entity_authority_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_authority_scope`
        CHECK (CHAR_LENGTH(`server_scope`) BETWEEN 1 AND 64
            AND `server_scope` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_authority_instance`
        CHECK (CHAR_LENGTH(`instance_id`) BETWEEN 3 AND 96
            AND `instance_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_authority_token`
        CHECK (CHAR_LENGTH(`authority_token`) BETWEEN 8 AND 96
            AND `authority_token` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_authority_resource_epoch`
        CHECK (`resource_epoch` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_authority_generation`
        CHECK (`lease_generation` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_authority_state`
        CHECK ((`lease_state` = 'active'
                AND `released_at` IS NULL
                AND `lease_until` > `heartbeat_at`)
            OR (`lease_state` = 'released' AND `released_at` IS NOT NULL
                AND `lease_until` <= `released_at`)),
    CONSTRAINT `ck_synex_entity_authority_times`
        CHECK (`heartbeat_at` >= `claimed_at`
            AND `lease_until` >= `heartbeat_at`),
    CONSTRAINT `ck_synex_entity_authority_trace`
        CHECK (CHAR_LENGTH(`last_trace_id`) BETWEEN 8 AND 128
            AND `last_trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_authority_version`
        CHECK (`version` BETWEEN 1 AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_entity_recovery_history` (
    `recovery_id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `entity_id` VARCHAR(64) NOT NULL,
    `entity_generation` BIGINT UNSIGNED NOT NULL,
    `lease_generation` BIGINT UNSIGNED NOT NULL,
    `attempt_number` INT UNSIGNED NOT NULL,
    `outcome` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `instance_id` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `failure_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `next_retry_at` DATETIME(6) NULL,
    `duration_ms` INT UNSIGNED NULL,
    `trace_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `details_json` LONGTEXT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `retain_until` DATETIME(6) NOT NULL,
    PRIMARY KEY (`recovery_id`),
    KEY `idx_synex_entity_recovery_entity`
        (`entity_id`, `entity_generation`, `occurred_at`, `recovery_id`),
    KEY `idx_synex_entity_recovery_failures`
        (`outcome`, `occurred_at`, `entity_id`),
    KEY `idx_synex_entity_recovery_retention`
        (`retain_until`, `recovery_id`),
    CONSTRAINT `fk_synex_entity_recovery_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_recovery_generation`
        CHECK (`entity_generation` BETWEEN 1 AND 9007199254740991
            AND `lease_generation` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_recovery_attempt`
        CHECK (`attempt_number` BETWEEN 1 AND 1000),
    CONSTRAINT `ck_synex_entity_recovery_outcome`
        CHECK (`outcome` IN (
            'scheduled', 'started', 'recovered', 'failed', 'paused', 'cancelled'
        )),
    CONSTRAINT `ck_synex_entity_recovery_instance`
        CHECK (CHAR_LENGTH(`instance_id`) BETWEEN 3 AND 96
            AND `instance_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_recovery_failure`
        CHECK ((`outcome` IN ('failed', 'paused')
                AND `failure_code` IS NOT NULL
                AND CHAR_LENGTH(`failure_code`) BETWEEN 3 AND 64
                AND `failure_code` REGEXP '^[A-Z][A-Z0-9_]*$')
            OR (`outcome` NOT IN ('failed', 'paused') AND `failure_code` IS NULL)),
    CONSTRAINT `ck_synex_entity_recovery_retry`
        CHECK (`next_retry_at` IS NULL
            OR (`outcome` IN ('scheduled', 'failed')
                AND `next_retry_at` > `occurred_at`)),
    CONSTRAINT `ck_synex_entity_recovery_duration`
        CHECK (`duration_ms` IS NULL OR `duration_ms` <= 3600000),
    CONSTRAINT `ck_synex_entity_recovery_trace`
        CHECK (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 128
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_recovery_details`
        CHECK (`details_json` IS NULL OR (JSON_VALID(`details_json`)
            AND OCTET_LENGTH(`details_json`) BETWEEN 2 AND 8192)),
    CONSTRAINT `ck_synex_entity_recovery_retention`
        CHECK (`retain_until` > `occurred_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
