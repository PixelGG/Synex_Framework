CREATE TABLE IF NOT EXISTS `synex_access_bans` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `identifier_id` BIGINT UNSIGNED NULL,
    `reason` VARCHAR(512) NOT NULL,
    `issued_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `expires_at` DATETIME(6) NULL,
    `revoked_at` DATETIME(6) NULL,
    `revoked_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `revocation_reason` VARCHAR(512) NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    KEY `idx_access_bans_user` (`user_id`, `revoked_at`, `expires_at`),
    KEY `idx_access_bans_identifier` (`identifier_id`, `revoked_at`, `expires_at`),
    KEY `idx_access_bans_expiry` (`expires_at`, `revoked_at`),
    CONSTRAINT `fk_access_bans_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_access_bans_identifier`
        FOREIGN KEY (`identifier_id`) REFERENCES `synex_identifiers` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_access_bans_target`
        CHECK ((`user_id` IS NOT NULL) <> (`identifier_id` IS NOT NULL)),
    CONSTRAINT `chk_access_bans_reason`
        CHECK (CHAR_LENGTH(`reason`) BETWEEN 1 AND 512),
    CONSTRAINT `chk_access_bans_expiry`
        CHECK (`expires_at` IS NULL OR `expires_at` > `created_at`),
    CONSTRAINT `chk_access_bans_revocation`
        CHECK ((`revoked_at` IS NULL AND `revoked_by_ref` IS NULL AND `revocation_reason` IS NULL)
            OR (`revoked_at` IS NOT NULL AND `revoked_by_ref` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_allowlist_entries` (
    `id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `user_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `identifier_id` BIGINT UNSIGNED NULL,
    `granted_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `expires_at` DATETIME(6) NULL,
    `revoked_at` DATETIME(6) NULL,
    `revoked_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    KEY `idx_allowlist_entries_user` (`user_id`, `revoked_at`, `expires_at`),
    KEY `idx_allowlist_entries_identifier` (`identifier_id`, `revoked_at`, `expires_at`),
    KEY `idx_allowlist_entries_expiry` (`expires_at`, `revoked_at`),
    CONSTRAINT `fk_allowlist_entries_user`
        FOREIGN KEY (`user_id`) REFERENCES `synex_users` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_allowlist_entries_identifier`
        FOREIGN KEY (`identifier_id`) REFERENCES `synex_identifiers` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_allowlist_entries_target`
        CHECK ((`user_id` IS NOT NULL) <> (`identifier_id` IS NOT NULL)),
    CONSTRAINT `chk_allowlist_entries_expiry`
        CHECK (`expires_at` IS NULL OR `expires_at` > `created_at`),
    CONSTRAINT `chk_allowlist_entries_revocation`
        CHECK ((`revoked_at` IS NULL AND `revoked_by_ref` IS NULL)
            OR (`revoked_at` IS NOT NULL AND `revoked_by_ref` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
