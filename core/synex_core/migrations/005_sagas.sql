CREATE TABLE IF NOT EXISTS `synex_sagas` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `saga_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `correlation_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `current_step` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `context_json` LONGTEXT NOT NULL,
    `last_error_json` LONGTEXT NULL,
    `deadline_at` DATETIME(6) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_sagas_public_id` (`public_id`),
    UNIQUE KEY `uq_sagas_type_correlation` (`saga_type`, `correlation_id`),
    KEY `idx_sagas_dispatch` (`state`, `deadline_at`, `id`),
    CONSTRAINT `chk_sagas_state`
        CHECK (`state` IN ('pending', 'running', 'compensating', 'completed', 'failed', 'cancelled')),
    CONSTRAINT `chk_sagas_context_json`
        CHECK (JSON_VALID(`context_json`)),
    CONSTRAINT `chk_sagas_last_error_json`
        CHECK (`last_error_json` IS NULL OR JSON_VALID(`last_error_json`)),
    CONSTRAINT `chk_sagas_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_saga_steps` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `saga_id` BIGINT UNSIGNED NOT NULL,
    `sequence_no` SMALLINT UNSIGNED NOT NULL,
    `step_name` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `event_type` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `attempt` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `payload_json` LONGTEXT NOT NULL,
    `error_json` LONGTEXT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_saga_steps_sequence` (`saga_id`, `sequence_no`),
    KEY `idx_saga_steps_name` (`saga_id`, `step_name`, `attempt`),
    CONSTRAINT `fk_saga_steps_saga`
        FOREIGN KEY (`saga_id`) REFERENCES `synex_sagas` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_saga_steps_sequence`
        CHECK (`sequence_no` > 0),
    CONSTRAINT `chk_saga_steps_event_type`
        CHECK (`event_type` IN ('started', 'succeeded', 'failed', 'compensated')),
    CONSTRAINT `chk_saga_steps_attempt`
        CHECK (`attempt` > 0),
    CONSTRAINT `chk_saga_steps_payload_json`
        CHECK (JSON_VALID(`payload_json`)),
    CONSTRAINT `chk_saga_steps_error_json`
        CHECK (`error_json` IS NULL OR JSON_VALID(`error_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
