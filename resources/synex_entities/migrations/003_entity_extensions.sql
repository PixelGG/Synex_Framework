CREATE TABLE IF NOT EXISTS `synex_entity_bindings` (
    `binding_id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `entity_id` VARCHAR(64) NOT NULL,
    `binding_namespace` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `binding_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `release_reason_code` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    `released_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED GENERATED ALWAYS AS (
        CASE WHEN `released_at` IS NULL THEN 1 ELSE NULL END
    ) STORED,
    PRIMARY KEY (`binding_id`),
    UNIQUE KEY `uq_synex_entity_bindings_active_ref`
        (`binding_namespace`, `binding_ref`, `active_marker`),
    UNIQUE KEY `uq_synex_entity_bindings_active_entity`
        (`entity_id`, `active_marker`),
    KEY `idx_synex_entity_bindings_entity_history`
        (`entity_id`, `created_at`, `binding_id`),
    KEY `idx_synex_entity_bindings_owner`
        (`owner_resource`, `active_marker`, `binding_id`),
    CONSTRAINT `fk_synex_entity_bindings_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_bindings_namespace`
        CHECK (CHAR_LENGTH(`binding_namespace`) BETWEEN 3 AND 128
            AND `binding_namespace` REGEXP '^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$'),
    CONSTRAINT `ck_synex_entity_bindings_ref`
        CHECK (CHAR_LENGTH(`binding_ref`) BETWEEN 1 AND 128
            AND `binding_ref` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_bindings_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `ck_synex_entity_bindings_release`
        CHECK ((`released_at` IS NULL AND `release_reason_code` IS NULL)
            OR (`released_at` IS NOT NULL
                AND `release_reason_code` IS NOT NULL
                AND CHAR_LENGTH(`release_reason_code`) BETWEEN 3 AND 128
                AND `release_reason_code` REGEXP '^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$')),
    CONSTRAINT `ck_synex_entity_bindings_version`
        CHECK (`version` BETWEEN 1 AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_entity_components` (
    `entity_id` VARCHAR(64) NOT NULL,
    `component_namespace` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` BIGINT UNSIGNED NOT NULL,
    `persistence_mode` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `payload_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`entity_id`, `component_namespace`),
    KEY `idx_synex_entity_components_owner`
        (`owner_resource`, `component_namespace`, `entity_id`),
    CONSTRAINT `fk_synex_entity_components_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_components_namespace`
        CHECK (CHAR_LENGTH(`component_namespace`) BETWEEN 3 AND 128
            AND `component_namespace` REGEXP '^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$'),
    CONSTRAINT `ck_synex_entity_components_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `ck_synex_entity_components_schema`
        CHECK (`schema_version` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_components_mode`
        CHECK (`persistence_mode` IN ('persistent', 'replicated')),
    CONSTRAINT `ck_synex_entity_components_payload`
        CHECK (JSON_VALID(`payload_json`)
            AND OCTET_LENGTH(`payload_json`) BETWEEN 2 AND 32768),
    CONSTRAINT `ck_synex_entity_components_version`
        CHECK (`version` BETWEEN 1 AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_entity_states` (
    `entity_id` VARCHAR(64) NOT NULL,
    `state_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` BIGINT UNSIGNED NOT NULL,
    `authority_mode` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `replication_mode` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `value_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`entity_id`, `state_key`),
    KEY `idx_synex_entity_states_owner`
        (`owner_resource`, `state_key`, `entity_id`),
    CONSTRAINT `fk_synex_entity_states_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_states_key`
        CHECK (CHAR_LENGTH(`state_key`) BETWEEN 3 AND 128
            AND `state_key` REGEXP '^[a-z][a-z0-9_]*[:.][a-z][a-z0-9_.:-]*$'),
    CONSTRAINT `ck_synex_entity_states_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `ck_synex_entity_states_schema`
        CHECK (`schema_version` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_states_authority`
        CHECK (`authority_mode` IN ('server', 'client_observed')),
    CONSTRAINT `ck_synex_entity_states_replication`
        CHECK (`replication_mode` IN ('none', 'scoped')
            AND (`authority_mode` = 'server' OR `replication_mode` = 'scoped')),
    CONSTRAINT `ck_synex_entity_states_value`
        CHECK (JSON_VALID(`value_json`)
            AND OCTET_LENGTH(`value_json`) BETWEEN 1 AND 8192),
    CONSTRAINT `ck_synex_entity_states_version`
        CHECK (`version` BETWEEN 1 AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_entity_tags` (
    `entity_id` VARCHAR(64) NOT NULL,
    `tag` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`entity_id`, `tag`),
    KEY `idx_synex_entity_tags_query` (`tag`, `entity_id`),
    KEY `idx_synex_entity_tags_owner` (`owner_resource`, `entity_id`),
    CONSTRAINT `fk_synex_entity_tags_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_tags_name`
        CHECK (CHAR_LENGTH(`tag`) BETWEEN 3 AND 128
            AND `tag` REGEXP '^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$'),
    CONSTRAINT `ck_synex_entity_tags_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_entity_checkpoints` (
    `entity_id` VARCHAR(64) NOT NULL,
    `entity_generation` BIGINT UNSIGNED NOT NULL,
    `position_x` DOUBLE NOT NULL,
    `position_y` DOUBLE NOT NULL,
    `position_z` DOUBLE NOT NULL,
    `heading` DOUBLE NOT NULL,
    `bucket_id` INT UNSIGNED NOT NULL DEFAULT 0,
    `generic_state_json` LONGTEXT NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_code` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `checkpointed_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`entity_id`),
    KEY `idx_synex_entity_checkpoints_source`
        (`source_resource`, `checkpointed_at`, `entity_id`),
    CONSTRAINT `fk_synex_entity_checkpoints_entity`
        FOREIGN KEY (`entity_id`) REFERENCES `synex_entities` (`entity_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `ck_synex_entity_checkpoints_generation`
        CHECK (`entity_generation` BETWEEN 1 AND 9007199254740991),
    CONSTRAINT `ck_synex_entity_checkpoints_position`
        CHECK (ABS(`position_x`) <= 20000
            AND ABS(`position_y`) <= 20000
            AND ABS(`position_z`) <= 20000
            AND `heading` >= 0 AND `heading` < 360
            AND `bucket_id` <= 2147483647),
    CONSTRAINT `ck_synex_entity_checkpoints_state`
        CHECK (JSON_VALID(`generic_state_json`)
            AND OCTET_LENGTH(`generic_state_json`) BETWEEN 2 AND 16384),
    CONSTRAINT `ck_synex_entity_checkpoints_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `ck_synex_entity_checkpoints_reason`
        CHECK (CHAR_LENGTH(`reason_code`) BETWEEN 3 AND 128
            AND `reason_code` REGEXP '^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$'),
    CONSTRAINT `ck_synex_entity_checkpoints_trace`
        CHECK (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 128
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `ck_synex_entity_checkpoints_version`
        CHECK (`version` BETWEEN 1 AND 9007199254740991)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
