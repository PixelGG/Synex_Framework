CREATE TABLE IF NOT EXISTS `synex_users` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `locale` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'en',
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    `deleted_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    KEY `idx_users_status` (`status`, `id`),
    CONSTRAINT `chk_users_status`
        CHECK (`status` IN ('active', 'suspended', 'anonymized', 'deleted')),
    CONSTRAINT `chk_users_locale`
        CHECK (`locale` REGEXP '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})?$'),
    CONSTRAINT `chk_users_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_users_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_identifiers` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `identifier_type` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `identifier_value` VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `verified_at` DATETIME(6) NULL,
    `first_seen_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `last_seen_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_identifiers_type_value` (`identifier_type`, `identifier_value`),
    KEY `idx_identifiers_user` (`user_id`, `identifier_type`),
    CONSTRAINT `fk_identifiers_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_identifiers_type`
        CHECK (`identifier_type` REGEXP '^[a-z][a-z0-9_]{1,31}$'),
    CONSTRAINT `chk_identifiers_value`
        CHECK (CHAR_LENGTH(`identifier_value`) BETWEEN 1 AND 255),
    CONSTRAINT `chk_identifiers_seen_window`
        CHECK (`last_seen_at` >= `first_seen_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_character_slots` (
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `slot_limit` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`user_id`),
    CONSTRAINT `fk_character_slots_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_character_slots_limit`
        CHECK (`slot_limit` BETWEEN 1 AND 32),
    CONSTRAINT `chk_character_slots_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_characters` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `slot` SMALLINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `first_name` VARCHAR(64) NOT NULL,
    `last_name` VARCHAR(64) NOT NULL,
    `date_of_birth` DATE NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    `deleted_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_characters_user_slot` (`user_id`, `slot`),
    UNIQUE KEY `uq_characters_id_user` (`id`, `user_id`),
    KEY `idx_characters_user_status` (`user_id`, `status`, `id`),
    CONSTRAINT `fk_characters_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_characters_slot`
        CHECK (`slot` BETWEEN 1 AND 32),
    CONSTRAINT `chk_characters_status`
        CHECK (`status` IN ('active', 'archived', 'anonymized', 'deleted')),
    CONSTRAINT `chk_characters_metadata_json`
        CHECK (JSON_VALID(`metadata_json`)),
    CONSTRAINT `chk_characters_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_sessions` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `server_instance_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_value` INT UNSIGNED NOT NULL,
    `source_generation` BIGINT UNSIGNED NOT NULL,
    `state` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'CONNECTING',
    `character_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `connected_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `last_seen_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `closed_at` DATETIME(6) NULL,
    `close_reason` VARCHAR(128) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_sessions_instance_source_generation` (`server_instance_id`, `source_value`, `source_generation`),
    KEY `idx_sessions_user_state` (`user_id`, `state`, `id`),
    KEY `idx_sessions_character_state` (`character_id`, `state`, `id`),
    KEY `idx_sessions_instance_state` (`server_instance_id`, `state`, `last_seen_at`),
    CONSTRAINT `fk_sessions_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_sessions_character_owner`
        FOREIGN KEY (`character_id`, `user_id`) REFERENCES `synex_characters` (`id`, `user_id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_sessions_state`
        CHECK (`state` IN ('CONNECTING', 'AUTHENTICATING', 'AUTHENTICATED', 'SELECTING_CHARACTER',
            'LOADING_CHARACTER', 'ACTIVE', 'UNLOADING_CHARACTER', 'DISCONNECTING', 'CLOSED')),
    CONSTRAINT `chk_sessions_seen_window`
        CHECK (`last_seen_at` >= `connected_at`),
    CONSTRAINT `chk_sessions_closed_at`
        CHECK ((`state` = 'CLOSED' AND `closed_at` IS NOT NULL) OR (`state` <> 'CLOSED' AND `closed_at` IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
